package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"runtime/debug"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	quic "github.com/quic-go/quic-go"
)

const defaultALPN = "moqx-test"
const quicGoModulePath = "github.com/quic-go/quic-go"
const streamPressureWorkload = "stream_pressure"
const datagramPressureWorkload = "datagram_pressure"
const datagramHeaderSize = 16

type serverConfig struct {
	addr     string
	certFile string
	keyFile  string
	alpn     string
}

type clientConfig struct {
	addr       string
	caFile     string
	alpn       string
	serverName string
	bidiEcho   string
	jsonOutput bool

	workload        string
	streamDirection string
	streamCount     int
	payloadSize     int
	payloadCount    int
	datagramSize    int
	datagramCount   int
}

type clientRunResult struct {
	SchemaVersion         string             `json:"schema_version"`
	RecordType            string             `json:"record_type"`
	Tool                  string             `json:"tool"`
	ReferenceImpl         string             `json:"reference_implementation"`
	ReferenceVersion      string             `json:"reference_version"`
	StartedAt             string             `json:"started_at"`
	FinishedAt            string             `json:"finished_at"`
	RemoteAddr            string             `json:"remote_addr"`
	ALPN                  string             `json:"alpn"`
	Workload              string             `json:"workload"`
	StreamDirection       string             `json:"stream_direction"`
	StreamCount           int                `json:"stream_count"`
	PayloadSizeBytes      int                `json:"payload_size_bytes"`
	PayloadCount          int                `json:"payload_count"`
	DatagramSizeBytes     int                `json:"datagram_size_bytes"`
	DatagramCount         int                `json:"datagram_count"`
	DatagramsOffered      int                `json:"datagrams_offered"`
	DatagramsAccepted     int                `json:"datagrams_accepted"`
	DatagramsReceived     int                `json:"datagrams_received"`
	DatagramDeliveryRatio float64            `json:"datagram_delivery_ratio"`
	DatagramDropCount     int                `json:"datagram_drop_count"`
	BytesSent             int64              `json:"bytes_sent"`
	BytesReceived         int64              `json:"bytes_received"`
	HandshakeLatencyMS    float64            `json:"handshake_latency_ms"`
	FirstByteLatencyMS    *float64           `json:"first_byte_latency_ms"`
	ApplicationDurationMS float64            `json:"application_duration_ms"`
	GoodputBPS            float64            `json:"goodput_bps"`
	SendRateDatagramPPS   float64            `json:"send_rate_datagrams_per_second"`
	StreamLatencyMS       map[string]float64 `json:"stream_latency_ms"`
	DatagramLatencyMS     map[string]float64 `json:"datagram_latency_ms"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	if err := run(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: quicprobe <server|client> [options]")
	}

	switch args[0] {
	case "server":
		cfg, err := parseServerConfig(args[1:])
		if err != nil {
			return err
		}

		return runServer(ctx, cfg, nil)

	case "client":
		cfg, timeout, err := parseClientConfig(args[1:])
		if err != nil {
			return err
		}

		clientCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		return runClient(clientCtx, cfg, stdout)

	default:
		return fmt.Errorf("unknown mode %q; expected server or client", args[0])
	}
}

func parseServerConfig(args []string) (serverConfig, error) {
	flags := flag.NewFlagSet("server", flag.ContinueOnError)
	flags.SetOutput(io.Discard)

	cfg := serverConfig{}
	flags.StringVar(&cfg.addr, "addr", ":4433", "UDP address to listen on")
	flags.StringVar(&cfg.certFile, "cert", "", "TLS certificate PEM file")
	flags.StringVar(&cfg.keyFile, "key", "", "TLS private key PEM file")
	flags.StringVar(&cfg.alpn, "alpn", envOrDefault("QUICPROBE_ALPN", defaultALPN), "QUIC ALPN")

	if err := flags.Parse(args); err != nil {
		return serverConfig{}, err
	}

	if cfg.certFile == "" || cfg.keyFile == "" {
		return serverConfig{}, errors.New("server requires --cert and --key")
	}
	if cfg.alpn == "" {
		return serverConfig{}, errors.New("server requires --alpn")
	}

	return cfg, nil
}

func parseClientConfig(args []string) (clientConfig, time.Duration, error) {
	flags := flag.NewFlagSet("client", flag.ContinueOnError)
	flags.SetOutput(io.Discard)

	cfg := clientConfig{}
	var timeout time.Duration
	flags.StringVar(&cfg.addr, "addr", "127.0.0.1:4433", "UDP server address")
	flags.StringVar(&cfg.caFile, "ca", "", "trusted CA certificate PEM file")
	flags.StringVar(&cfg.alpn, "alpn", envOrDefault("QUICPROBE_ALPN", defaultALPN), "QUIC ALPN")
	flags.StringVar(&cfg.serverName, "servername", "", "TLS server name override")
	flags.StringVar(&cfg.bidiEcho, "bidi-echo", "", "payload to send on a bidirectional stream and expect as echo")
	flags.BoolVar(&cfg.jsonOutput, "json", false, "emit structured JSON for a measured run")
	flags.StringVar(&cfg.workload, "workload", streamPressureWorkload, "workload for --json runs: stream_pressure or datagram_pressure")
	flags.StringVar(&cfg.streamDirection, "stream-direction", "bidirectional", "stream direction for --json runs: bidirectional or unidirectional")
	flags.IntVar(&cfg.streamCount, "stream-count", 1, "number of concurrent streams for --json runs")
	flags.IntVar(&cfg.payloadSize, "payload-size", 1200, "payload bytes per write for --json runs")
	flags.IntVar(&cfg.payloadCount, "payload-count", 1, "payload writes per stream for --json runs")
	flags.IntVar(&cfg.datagramSize, "datagram-size", 1200, "datagram bytes per send for datagram_pressure --json runs")
	flags.IntVar(&cfg.datagramCount, "datagram-count", 1000, "datagrams to send for datagram_pressure --json runs")
	flags.DurationVar(&timeout, "timeout", 5*time.Second, "client timeout")

	if err := flags.Parse(args); err != nil {
		return clientConfig{}, 0, err
	}

	if cfg.caFile == "" {
		return clientConfig{}, 0, errors.New("client requires --ca")
	}
	if cfg.alpn == "" {
		return clientConfig{}, 0, errors.New("client requires --alpn")
	}
	if timeout <= 0 {
		return clientConfig{}, 0, errors.New("client --timeout must be positive")
	}
	if cfg.workload != streamPressureWorkload && cfg.workload != datagramPressureWorkload {
		return clientConfig{}, 0, errors.New("client --workload must be stream_pressure or datagram_pressure")
	}
	if cfg.streamDirection != "bidirectional" && cfg.streamDirection != "unidirectional" {
		return clientConfig{}, 0, errors.New("client --stream-direction must be bidirectional or unidirectional")
	}
	if cfg.streamCount <= 0 {
		return clientConfig{}, 0, errors.New("client --stream-count must be positive")
	}
	if cfg.payloadSize <= 0 {
		return clientConfig{}, 0, errors.New("client --payload-size must be positive")
	}
	if cfg.payloadCount <= 0 {
		return clientConfig{}, 0, errors.New("client --payload-count must be positive")
	}
	if cfg.datagramSize < datagramHeaderSize {
		return clientConfig{}, 0, fmt.Errorf("client --datagram-size must be at least %d", datagramHeaderSize)
	}
	if cfg.datagramCount <= 0 {
		return clientConfig{}, 0, errors.New("client --datagram-count must be positive")
	}

	return cfg, timeout, nil
}

func runServer(ctx context.Context, cfg serverConfig, ready chan<- string) error {
	cert, err := tls.LoadX509KeyPair(cfg.certFile, cfg.keyFile)
	if err != nil {
		return fmt.Errorf("load server certificate: %w", err)
	}

	listener, err := quic.ListenAddr(cfg.addr, &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{cfg.alpn},
	}, &quic.Config{EnableDatagrams: true})
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()

	if ready != nil {
		ready <- listener.Addr().String()
	}

	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}

			return fmt.Errorf("accept connection: %w", err)
		}

		go handleConnection(ctx, conn)
	}
}

func handleConnection(ctx context.Context, conn quic.Connection) {
	var wg sync.WaitGroup
	wg.Add(3)

	go func() {
		defer wg.Done()
		acceptBidiStreams(ctx, conn)
	}()

	go func() {
		defer wg.Done()
		acceptUniStreams(ctx, conn)
	}()

	go func() {
		defer wg.Done()
		echoDatagrams(ctx, conn)
	}()

	wg.Wait()
}

func acceptBidiStreams(ctx context.Context, conn quic.Connection) {
	for {
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			return
		}

		go handleBidiEchoStream(stream)
	}
}

func acceptUniStreams(ctx context.Context, conn quic.Connection) {
	for {
		stream, err := conn.AcceptUniStream(ctx)
		if err != nil {
			return
		}

		go drainUniStream(stream)
	}
}

func handleBidiEchoStream(stream quic.Stream) {
	if err := echoStream(stream); err != nil {
		stream.CancelWrite(1)
		return
	}

	_ = stream.Close()
}

func echoStream(stream quic.Stream) error {
	buffer := make([]byte, 32*1024)

	for {
		n, readErr := stream.Read(buffer)
		if n > 0 {
			if _, err := writeFull(stream, buffer[:n]); err != nil {
				return err
			}
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			return readErr
		}
	}
}

func drainUniStream(stream quic.ReceiveStream) {
	_, _ = io.Copy(io.Discard, stream)
}

func echoDatagrams(ctx context.Context, conn quic.Connection) {
	for {
		datagram, err := conn.ReceiveDatagram(ctx)
		if err != nil {
			return
		}
		if err := conn.SendDatagram(datagram); err != nil {
			return
		}
	}
}

func runClient(ctx context.Context, cfg clientConfig, stdout io.Writer) error {
	caPEM, err := os.ReadFile(cfg.caFile)
	if err != nil {
		return fmt.Errorf("read CA certificate: %w", err)
	}

	roots := x509.NewCertPool()
	if ok := roots.AppendCertsFromPEM(caPEM); !ok {
		return errors.New("CA certificate file did not contain a PEM certificate")
	}

	serverName, err := serverNameFor(cfg.addr, cfg.serverName)
	if err != nil {
		return err
	}

	startedAt := time.Now()

	conn, err := quic.DialAddr(ctx, cfg.addr, &tls.Config{
		MinVersion: tls.VersionTLS13,
		RootCAs:    roots,
		ServerName: serverName,
		NextProtos: []string{cfg.alpn},
	}, &quic.Config{EnableDatagrams: true})
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.CloseWithError(0, "done")

	handshakeLatency := time.Since(startedAt)

	if cfg.jsonOutput {
		result, err := runMeasuredClient(ctx, cfg, conn, startedAt, handshakeLatency)
		if err != nil {
			return err
		}

		encoder := json.NewEncoder(stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(result)
	}

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return fmt.Errorf("open bidirectional stream: %w", err)
	}

	if _, err := stream.Write([]byte(cfg.bidiEcho)); err != nil {
		return fmt.Errorf("write echo payload: %w", err)
	}
	if err := stream.Close(); err != nil {
		return fmt.Errorf("close stream write side: %w", err)
	}

	echo := make([]byte, len(cfg.bidiEcho))
	if _, err := io.ReadFull(stream, echo); err != nil {
		return fmt.Errorf("read echo payload: %w", err)
	}
	if string(echo) != cfg.bidiEcho {
		return fmt.Errorf("echo mismatch: got %q want %q", string(echo), cfg.bidiEcho)
	}

	if _, err := stdout.Write(echo); err != nil {
		return fmt.Errorf("write stdout: %w", err)
	}

	return nil
}

func runMeasuredClient(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	startedAt time.Time,
	handshakeLatency time.Duration,
) (clientRunResult, error) {
	if cfg.workload == "" {
		cfg.workload = streamPressureWorkload
	}

	switch cfg.workload {
	case streamPressureWorkload:
		return runStreamPressureClient(ctx, cfg, conn, startedAt, handshakeLatency)
	case datagramPressureWorkload:
		return runDatagramPressureClient(ctx, cfg, conn, startedAt, handshakeLatency)
	default:
		return clientRunResult{}, fmt.Errorf("unsupported workload %q", cfg.workload)
	}
}

func runStreamPressureClient(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	startedAt time.Time,
	handshakeLatency time.Duration,
) (clientRunResult, error) {
	applicationStartedAt := time.Now()
	payload := deterministicPayload(cfg.payloadSize)
	firstByte := make(chan time.Duration, 1)
	latencies := make([]float64, cfg.streamCount)

	var bytesSent int64
	var bytesReceived int64
	var wg sync.WaitGroup
	errc := make(chan error, cfg.streamCount)

	for index := 0; index < cfg.streamCount; index++ {
		index := index
		wg.Add(1)

		go func() {
			defer wg.Done()

			streamStartedAt := time.Now()

			sent, received, err := runPressureStream(
				ctx,
				cfg,
				conn,
				payload,
				firstByte,
				applicationStartedAt,
			)
			if err != nil {
				errc <- err
				return
			}

			atomic.AddInt64(&bytesSent, sent)
			atomic.AddInt64(&bytesReceived, received)
			latencies[index] = durationMillis(time.Since(streamStartedAt))
		}()
	}

	wg.Wait()
	close(errc)

	for err := range errc {
		if err != nil {
			return clientRunResult{}, err
		}
	}

	applicationDuration := time.Since(applicationStartedAt)
	finishedAt := time.Now()
	firstByteLatency := firstByteLatencyMS(firstByte)
	totalBytesSent := atomic.LoadInt64(&bytesSent)
	totalBytesReceived := atomic.LoadInt64(&bytesReceived)

	return clientRunResult{
		SchemaVersion:         "quicprobe-v1",
		RecordType:            "client_run",
		Tool:                  "quicprobe",
		ReferenceImpl:         "quic-go",
		ReferenceVersion:      moduleVersion(quicGoModulePath),
		StartedAt:             startedAt.UTC().Format(time.RFC3339Nano),
		FinishedAt:            finishedAt.UTC().Format(time.RFC3339Nano),
		RemoteAddr:            conn.RemoteAddr().String(),
		ALPN:                  conn.ConnectionState().TLS.NegotiatedProtocol,
		Workload:              streamPressureWorkload,
		StreamDirection:       cfg.streamDirection,
		StreamCount:           cfg.streamCount,
		PayloadSizeBytes:      cfg.payloadSize,
		PayloadCount:          cfg.payloadCount,
		BytesSent:             totalBytesSent,
		BytesReceived:         totalBytesReceived,
		HandshakeLatencyMS:    durationMillis(handshakeLatency),
		FirstByteLatencyMS:    firstByteLatency,
		ApplicationDurationMS: durationMillis(applicationDuration),
		GoodputBPS:            goodputBPS(totalBytesSent, totalBytesReceived, applicationDuration, cfg.streamDirection),
		StreamLatencyMS:       latencySummary(latencies),
	}, nil
}

func runDatagramPressureClient(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	startedAt time.Time,
	handshakeLatency time.Duration,
) (clientRunResult, error) {
	if !conn.ConnectionState().SupportsDatagrams {
		return clientRunResult{}, errors.New("peer did not advertise QUIC DATAGRAM support")
	}

	applicationStartedAt := time.Now()
	accepted, sendDuration, err := sendDatagramBurst(conn, cfg)
	if err != nil {
		return clientRunResult{}, err
	}

	received, firstByteLatency, latencies, err := receiveDatagramEchoes(ctx, conn, accepted, applicationStartedAt)
	if err != nil {
		return clientRunResult{}, err
	}

	applicationDuration := time.Since(applicationStartedAt)
	finishedAt := time.Now()
	drops := cfg.datagramCount - received
	bytesSent := int64(accepted * cfg.datagramSize)
	bytesReceived := int64(received * cfg.datagramSize)

	return clientRunResult{
		SchemaVersion:         "quicprobe-v1",
		RecordType:            "client_run",
		Tool:                  "quicprobe",
		ReferenceImpl:         "quic-go",
		ReferenceVersion:      moduleVersion(quicGoModulePath),
		StartedAt:             startedAt.UTC().Format(time.RFC3339Nano),
		FinishedAt:            finishedAt.UTC().Format(time.RFC3339Nano),
		RemoteAddr:            conn.RemoteAddr().String(),
		ALPN:                  conn.ConnectionState().TLS.NegotiatedProtocol,
		Workload:              datagramPressureWorkload,
		PayloadSizeBytes:      cfg.datagramSize,
		DatagramSizeBytes:     cfg.datagramSize,
		DatagramCount:         cfg.datagramCount,
		DatagramsOffered:      cfg.datagramCount,
		DatagramsAccepted:     accepted,
		DatagramsReceived:     received,
		DatagramDeliveryRatio: ratio(received, cfg.datagramCount),
		DatagramDropCount:     drops,
		BytesSent:             bytesSent,
		BytesReceived:         bytesReceived,
		HandshakeLatencyMS:    durationMillis(handshakeLatency),
		FirstByteLatencyMS:    firstByteLatency,
		ApplicationDurationMS: durationMillis(applicationDuration),
		GoodputBPS:            throughputBPS(bytesReceived, applicationDuration),
		SendRateDatagramPPS:   rate(accepted, sendDuration),
		DatagramLatencyMS:     latencySummary(latencies),
	}, nil
}

func sendDatagramBurst(conn quic.Connection, cfg clientConfig) (int, time.Duration, error) {
	startedAt := time.Now()

	for sequence := 1; sequence <= cfg.datagramCount; sequence++ {
		payload := datagramPayload(uint64(sequence), cfg.datagramSize, time.Now())
		if err := conn.SendDatagram(payload); err != nil {
			return sequence - 1, time.Since(startedAt), fmt.Errorf("send datagram %d: %w", sequence, err)
		}
	}

	return cfg.datagramCount, time.Since(startedAt), nil
}

func receiveDatagramEchoes(
	ctx context.Context,
	conn quic.Connection,
	expected int,
	firstByteOrigin time.Time,
) (int, *float64, []float64, error) {
	received := map[uint64]struct{}{}
	latencies := make([]float64, 0, expected)
	var firstByteLatency *float64

	for len(received) < expected {
		payload, err := conn.ReceiveDatagram(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return len(received), firstByteLatency, latencies, nil
			}

			return len(received), firstByteLatency, latencies, fmt.Errorf("receive datagram echo: %w", err)
		}

		sequence, sentAt, ok := parseDatagramPayload(payload)
		if !ok {
			continue
		}
		if _, duplicate := received[sequence]; duplicate {
			continue
		}

		latency := durationMillis(time.Since(sentAt))
		if firstByteLatency == nil {
			value := durationMillis(time.Since(firstByteOrigin))
			firstByteLatency = &value
		}

		received[sequence] = struct{}{}
		latencies = append(latencies, latency)
	}

	return len(received), firstByteLatency, latencies, nil
}

func runPressureStream(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	payload []byte,
	firstByte chan<- time.Duration,
	firstByteOrigin time.Time,
) (int64, int64, error) {
	switch cfg.streamDirection {
	case "bidirectional":
		return runBidiPressureStream(ctx, cfg, conn, payload, firstByte, firstByteOrigin)
	case "unidirectional":
		return runUniPressureStream(ctx, cfg, conn, payload)
	default:
		return 0, 0, fmt.Errorf("unsupported stream direction %q", cfg.streamDirection)
	}
}

func runBidiPressureStream(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	payload []byte,
	firstByte chan<- time.Duration,
	firstByteOrigin time.Time,
) (int64, int64, error) {
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("open bidirectional pressure stream: %w", err)
	}

	type writeResult struct {
		sent int64
		err  error
	}

	writec := make(chan writeResult, 1)
	go func() {
		sent, err := writePayloads(stream, payload, cfg.payloadCount)
		if err != nil {
			writec <- writeResult{sent: sent, err: fmt.Errorf("write bidirectional pressure stream: %w", err)}
			return
		}
		if err := stream.Close(); err != nil {
			writec <- writeResult{sent: sent, err: fmt.Errorf("close bidirectional pressure stream write side: %w", err)}
			return
		}

		writec <- writeResult{sent: sent}
	}()

	received, readErr := readEchoPayload(stream, payload, cfg.payloadCount, firstByte, firstByteOrigin)
	write := <-writec
	if write.err != nil {
		return write.sent, received, write.err
	}
	if readErr != nil {
		return write.sent, received, readErr
	}

	return write.sent, received, nil
}

func runUniPressureStream(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	payload []byte,
) (int64, int64, error) {
	stream, err := conn.OpenUniStreamSync(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("open unidirectional pressure stream: %w", err)
	}

	sent, err := writePayloads(stream, payload, cfg.payloadCount)
	if err != nil {
		return sent, 0, fmt.Errorf("write unidirectional pressure stream: %w", err)
	}
	if err := stream.Close(); err != nil {
		return sent, 0, fmt.Errorf("close unidirectional pressure stream: %w", err)
	}

	return sent, 0, nil
}

func writePayloads(writer io.Writer, payload []byte, count int) (int64, error) {
	var total int64

	for i := 0; i < count; i++ {
		n, err := writeFull(writer, payload)
		total += int64(n)
		if err != nil {
			return total, err
		}
	}

	return total, nil
}

func writeFull(writer io.Writer, payload []byte) (int, error) {
	var total int

	for total < len(payload) {
		n, err := writer.Write(payload[total:])
		total += n
		if err != nil {
			return total, err
		}
		if n == 0 {
			return total, io.ErrShortWrite
		}
	}

	return total, nil
}

func readEchoPayload(
	reader io.Reader,
	payload []byte,
	count int,
	firstByte chan<- time.Duration,
	firstByteOrigin time.Time,
) (int64, error) {
	expectedBytes := len(payload) * count
	if expectedBytes == 0 {
		return 0, nil
	}

	buffer := make([]byte, min(expectedBytes, 32*1024))
	var total int64
	firstByteReported := false

	for int(total) < expectedBytes {
		remaining := expectedBytes - int(total)
		readSize := min(remaining, len(buffer))

		n, err := reader.Read(buffer[:readSize])
		if n > 0 {
			if !firstByteReported {
				notifyFirstByte(firstByte, time.Since(firstByteOrigin))
				firstByteReported = true
			}

			if !matchesPayload(buffer[:n], payload, int(total)) {
				return total + int64(n), errors.New("echo payload mismatch")
			}

			total += int64(n)
		}
		if err != nil {
			if err == io.EOF && int(total) == expectedBytes {
				return total, nil
			}
			return total, fmt.Errorf("read echo payload: %w", err)
		}
	}

	return total, nil
}

func matchesPayload(chunk []byte, payload []byte, offset int) bool {
	for index, value := range chunk {
		if value != payload[(offset+index)%len(payload)] {
			return false
		}
	}

	return true
}

func notifyFirstByte(firstByte chan<- time.Duration, latency time.Duration) {
	select {
	case firstByte <- latency:
	default:
	}
}

func firstByteLatencyMS(firstByte <-chan time.Duration) *float64 {
	select {
	case latency := <-firstByte:
		value := durationMillis(latency)
		return &value
	default:
		return nil
	}
}

func deterministicPayload(size int) []byte {
	payload := make([]byte, size)
	for i := range payload {
		payload[i] = byte(i % 251)
	}
	return payload
}

func datagramPayload(sequence uint64, size int, sentAt time.Time) []byte {
	payload := deterministicPayload(size)
	binary.BigEndian.PutUint64(payload[0:8], sequence)
	binary.BigEndian.PutUint64(payload[8:16], uint64(sentAt.UnixNano()))
	return payload
}

func parseDatagramPayload(payload []byte) (uint64, time.Time, bool) {
	if len(payload) < datagramHeaderSize {
		return 0, time.Time{}, false
	}

	sequence := binary.BigEndian.Uint64(payload[0:8])
	sentAtNanos := int64(binary.BigEndian.Uint64(payload[8:16]))

	return sequence, time.Unix(0, sentAtNanos), true
}

func latencySummary(values []float64) map[string]float64 {
	if len(values) == 0 {
		return map[string]float64{"p50": 0, "p95": 0, "p99": 0}
	}

	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)

	return map[string]float64{
		"p50": percentile(sorted, 0.50),
		"p95": percentile(sorted, 0.95),
		"p99": percentile(sorted, 0.99),
	}
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 1 {
		return sorted[0]
	}

	index := int(float64(len(sorted)-1) * p)
	return sorted[index]
}

func durationMillis(duration time.Duration) float64 {
	return float64(duration.Microseconds()) / 1000.0
}

func goodputBPS(sent int64, received int64, duration time.Duration, direction string) float64 {
	seconds := duration.Seconds()
	if seconds <= 0 {
		return 0
	}

	bytes := received
	if direction == "unidirectional" {
		bytes = sent
	}

	return float64(bytes*8) / seconds
}

func throughputBPS(bytes int64, duration time.Duration) float64 {
	seconds := duration.Seconds()
	if seconds <= 0 {
		return 0
	}

	return float64(bytes*8) / seconds
}

func rate(count int, duration time.Duration) float64 {
	seconds := duration.Seconds()
	if seconds <= 0 {
		return 0
	}

	return float64(count) / seconds
}

func ratio(numerator int, denominator int) float64 {
	if denominator <= 0 {
		return 0
	}

	return float64(numerator) / float64(denominator)
}

func serverNameFor(addr string, override string) (string, error) {
	if override != "" {
		return override, nil
	}

	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return "", fmt.Errorf("split address %q: %w", addr, err)
	}

	return host, nil
}

func moduleVersion(path string) string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}

	for _, dep := range info.Deps {
		if dep.Path == path {
			return dep.Version
		}
	}

	return "unknown"
}

func envOrDefault(key string, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}

	return fallback
}
