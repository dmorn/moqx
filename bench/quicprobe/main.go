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
	"runtime"
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
const mixedMOQTShapedWorkload = "mixed_moqt_shaped"
const serverRunEvidenceSchema = "quicprobe-server-run-evidence-v1"
const serverRunEvidenceRecordType = "server_run_evidence"
const datagramHeaderSize = 16
const datagramEchoQueueLen = 131_072
const pacedSpinThreshold = 200 * time.Microsecond
const udpNetworkAuto = "auto"

type serverConfig struct {
	addr        string
	certFile    string
	keyFile     string
	alpn        string
	statsOutput string
	udpNetwork  string
	initialSize int
}

type clientConfig struct {
	addr        string
	caFile      string
	alpn        string
	serverName  string
	bidiEcho    string
	jsonOutput  bool
	udpNetwork  string
	initialSize int

	workload        string
	streamDirection string
	streamCount     int
	payloadSize     int
	payloadCount    int
	datagramSize    int
	datagramCount   int
	datagramRate    int
	durationSeconds int
	rateTolerance   float64

	controlPayloadSize  int
	controlMessageCount int
	controlRate         int
}

type clientRunResult struct {
	SchemaVersion                   string             `json:"schema_version"`
	RecordType                      string             `json:"record_type"`
	Tool                            string             `json:"tool"`
	ReferenceImpl                   string             `json:"reference_implementation"`
	ReferenceVersion                string             `json:"reference_version"`
	StartedAt                       string             `json:"started_at"`
	FinishedAt                      string             `json:"finished_at"`
	RemoteAddr                      string             `json:"remote_addr"`
	ALPN                            string             `json:"alpn"`
	Workload                        string             `json:"workload"`
	StreamDirection                 string             `json:"stream_direction"`
	StreamCount                     int                `json:"stream_count"`
	PayloadSizeBytes                int                `json:"payload_size_bytes"`
	PayloadCount                    int                `json:"payload_count"`
	ControlPayloadSizeBytes         int                `json:"control_payload_size_bytes,omitempty"`
	ControlMessageCount             int                `json:"control_message_count,omitempty"`
	ControlMessagesPerSecond        float64            `json:"control_messages_per_second,omitempty"`
	ControlTrickleBPS               float64            `json:"control_trickle_bps,omitempty"`
	DatagramSizeBytes               int                `json:"datagram_size_bytes"`
	DatagramCount                   int                `json:"datagram_count"`
	DatagramMode                    string             `json:"datagram_mode"`
	TargetDatagramPPS               float64            `json:"target_datagrams_per_second"`
	TargetDurationSeconds           int                `json:"target_duration_seconds"`
	OfferedRateRatio                float64            `json:"offered_rate_ratio"`
	OfferedRateTolerance            float64            `json:"offered_rate_tolerance"`
	OfferedRateValid                bool               `json:"offered_rate_valid"`
	DatagramsOffered                int                `json:"datagrams_offered"`
	DatagramsAccepted               int                `json:"datagrams_accepted"`
	DatagramsReceived               int                `json:"datagrams_received"`
	DatagramDeliveryRatio           float64            `json:"datagram_delivery_ratio"`
	DatagramDropCount               int                `json:"datagram_drop_count"`
	BytesSent                       int64              `json:"bytes_sent"`
	BytesReceived                   int64              `json:"bytes_received"`
	HandshakeLatencyMS              float64            `json:"handshake_latency_ms"`
	FirstByteLatencyMS              *float64           `json:"first_byte_latency_ms"`
	ApplicationDurationMS           float64            `json:"application_duration_ms"`
	SendDurationMS                  float64            `json:"send_duration_ms"`
	TargetSendDurationMS            float64            `json:"target_send_duration_ms,omitempty"`
	ScheduledSendSpanMS             float64            `json:"scheduled_send_span_ms,omitempty"`
	OfferedLoadBPS                  float64            `json:"offered_load_bps"`
	GoodputBPS                      float64            `json:"goodput_bps"`
	SendRatePacketsPPS              float64            `json:"send_rate_packets_per_second,omitempty"`
	SendRateDatagramPPS             float64            `json:"send_rate_datagrams_per_second"`
	SendPacingLateCount             int                `json:"send_pacing_late_count,omitempty"`
	SendPacingLagMS                 map[string]float64 `json:"send_pacing_lag_ms,omitempty"`
	SendDatagramCallSlowCount       int                `json:"send_datagram_call_slow_count,omitempty"`
	SendDatagramCallSlowThresholdMS float64            `json:"send_datagram_call_slow_threshold_ms,omitempty"`
	SendDatagramCallTotalMS         float64            `json:"send_datagram_call_total_ms,omitempty"`
	SendDatagramCallMS              map[string]float64 `json:"send_datagram_call_ms,omitempty"`
	StreamScheduling                string             `json:"stream_scheduling,omitempty"`
	StreamLatencyMS                 map[string]float64 `json:"stream_latency_ms"`
	DatagramLatencyMS               map[string]float64 `json:"datagram_latency_ms"`
	ControlLatencyMS                map[string]float64 `json:"control_latency_ms,omitempty"`
}

type serverRunEvidence struct {
	SchemaVersion                string  `json:"schema_version"`
	RecordType                   string  `json:"record_type"`
	Tool                         string  `json:"tool"`
	ReferenceImpl                string  `json:"reference_implementation"`
	ReferenceVersion             string  `json:"reference_version"`
	RunSequence                  uint64  `json:"run_sequence"`
	StartedAt                    string  `json:"started_at"`
	FinishedAt                   string  `json:"finished_at"`
	LocalAddr                    string  `json:"local_addr"`
	RemoteAddr                   string  `json:"remote_addr"`
	ALPN                         string  `json:"alpn"`
	DurationMS                   float64 `json:"duration_ms"`
	BidiStreamSemantics          string  `json:"bidi_stream_semantics"`
	UniStreamSemantics           string  `json:"uni_stream_semantics"`
	DatagramSemantics            string  `json:"datagram_semantics"`
	DatagramsReceived            int     `json:"datagrams_received"`
	DatagramsEchoAccepted        int     `json:"datagrams_echo_accepted"`
	DatagramBytesReceived        int64   `json:"datagram_bytes_received"`
	DatagramBytesEchoAccepted    int64   `json:"datagram_bytes_echo_accepted"`
	BidiStreamsAccepted          int     `json:"bidi_streams_accepted"`
	UniStreamsAccepted           int     `json:"uni_streams_accepted"`
	StreamsCompleted             int     `json:"streams_completed"`
	StreamBytesReceived          int64   `json:"stream_bytes_received"`
	StreamBytesEchoAccepted      int64   `json:"stream_bytes_echo_accepted"`
	StreamReceiveErrorCount      int     `json:"stream_receive_error_count"`
	StreamSendErrorCount         int     `json:"stream_send_error_count"`
	EchoQueueCapacity            int     `json:"echo_queue_capacity,omitempty"`
	EchoQueueMaxDepth            int     `json:"echo_queue_max_depth,omitempty"`
	DatagramReceiveError         string  `json:"datagram_receive_error,omitempty"`
	DatagramSendError            string  `json:"datagram_send_error,omitempty"`
	StreamReceiveError           string  `json:"stream_receive_error,omitempty"`
	StreamSendError              string  `json:"stream_send_error,omitempty"`
	FirstDatagramLatencyMS       float64 `json:"first_datagram_latency_ms,omitempty"`
	FirstStreamByteLatencyMS     float64 `json:"first_stream_byte_latency_ms,omitempty"`
	ReceiverEvidenceComplete     bool    `json:"receiver_evidence_complete"`
	ReceiverEvidenceFailureCause string  `json:"receiver_evidence_failure_cause,omitempty"`
}

type serverRunEvidenceRecorder struct {
	mu          sync.Mutex
	sequence    atomic.Uint64
	stdout      io.Writer
	statsOutput string
}

type datagramEchoStats struct {
	startedAt             time.Time
	finishedAt            time.Time
	localAddr             string
	remoteAddr            string
	datagramsReceived     int
	datagramsEchoAccepted int
	bytesReceived         int64
	bytesEchoAccepted     int64
	echoQueueCapacity     int
	echoQueueMaxDepth     int
	receiveErr            error
	sendErr               error
	firstDatagramLatency  time.Duration
}

type serverConnectionStats struct {
	mu                     sync.Mutex
	startedAt              time.Time
	finishedAt             time.Time
	localAddr              string
	remoteAddr             string
	alpn                   string
	datagrams              datagramEchoStats
	bidiStreamsAccepted    int
	uniStreamsAccepted     int
	streamsCompleted       int
	streamBytesReceived    int64
	streamBytesEchoed      int64
	streamReceiveErrCount  int
	streamSendErrCount     int
	streamReceiveErr       error
	streamSendErr          error
	firstStreamByteLatency time.Duration
}

type serverConnectionStatsSnapshot struct {
	startedAt                 time.Time
	finishedAt                time.Time
	localAddr                 string
	remoteAddr                string
	alpn                      string
	datagramsReceived         int
	datagramsEchoAccepted     int
	datagramBytesReceived     int64
	datagramBytesEchoAccepted int64
	echoQueueCapacity         int
	echoQueueMaxDepth         int
	datagramReceiveErr        error
	datagramSendErr           error
	firstDatagramLatency      time.Duration
	bidiStreamsAccepted       int
	uniStreamsAccepted        int
	streamsCompleted          int
	streamBytesReceived       int64
	streamBytesEchoed         int64
	streamReceiveErrCount     int
	streamSendErrCount        int
	streamReceiveErr          error
	streamSendErr             error
	firstStreamByteLatency    time.Duration
}

type datagramConn interface {
	ReceiveDatagram(context.Context) ([]byte, error)
	SendDatagram([]byte) error
	LocalAddr() net.Addr
	RemoteAddr() net.Addr
}

type datagramSendResult struct {
	accepted          int
	duration          time.Duration
	targetDuration    time.Duration
	scheduledSpan     time.Duration
	pacingLateCount   int
	pacingLagMillis   []float64
	sendCallSlowCount int
	sendCallTotal     time.Duration
	sendCallMillis    []float64
}

type datagramReceiveResult struct {
	received         int
	firstByteLatency *float64
	latencies        []float64
	err              error
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

		return runServer(ctx, cfg, nil, stdout)

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
	flags.StringVar(&cfg.statsOutput, "stats-output", "", "optional JSONL path for per-connection server ingress summaries")
	flags.StringVar(&cfg.udpNetwork, "udp-network", udpNetworkAuto, "UDP socket network: auto, udp, udp4, or udp6")
	flags.IntVar(&cfg.initialSize, "initial-packet-size", 0, "QUIC Initial packet size in bytes; 0 uses the quic-go default")

	if err := flags.Parse(args); err != nil {
		return serverConfig{}, err
	}

	if cfg.certFile == "" || cfg.keyFile == "" {
		return serverConfig{}, errors.New("server requires --cert and --key")
	}
	if cfg.alpn == "" {
		return serverConfig{}, errors.New("server requires --alpn")
	}
	if err := validateUDPNetwork(cfg.udpNetwork); err != nil {
		return serverConfig{}, err
	}
	if err := validateInitialPacketSize(cfg.initialSize); err != nil {
		return serverConfig{}, err
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
	flags.StringVar(&cfg.udpNetwork, "udp-network", udpNetworkAuto, "UDP socket network: auto, udp, udp4, or udp6")
	flags.IntVar(&cfg.initialSize, "initial-packet-size", 0, "QUIC Initial packet size in bytes; 0 uses the quic-go default")
	flags.StringVar(&cfg.workload, "workload", streamPressureWorkload, "workload for --json runs: stream_pressure or datagram_pressure")
	flags.StringVar(&cfg.streamDirection, "stream-direction", "bidirectional", "stream direction for --json runs: bidirectional or unidirectional")
	flags.IntVar(&cfg.streamCount, "stream-count", 1, "number of concurrent streams for --json runs")
	flags.IntVar(&cfg.payloadSize, "payload-size", 1200, "payload bytes per write for --json runs")
	flags.IntVar(&cfg.payloadCount, "payload-count", 1, "payload writes per stream for --json runs")
	flags.IntVar(&cfg.datagramSize, "datagram-size", 1200, "datagram bytes per send for datagram_pressure --json runs")
	flags.IntVar(&cfg.datagramCount, "datagram-count", 1000, "datagrams to send for datagram_pressure --json runs")
	flags.IntVar(&cfg.datagramRate, "datagram-rate", 0, "target datagrams per second for paced datagram_pressure --json runs")
	flags.IntVar(&cfg.durationSeconds, "duration-seconds", 0, "paced datagram_pressure duration in seconds")
	flags.Float64Var(&cfg.rateTolerance, "offered-rate-tolerance", 0.95, "minimum actual/target send rate ratio for paced datagram_pressure runs")
	flags.IntVar(&cfg.controlPayloadSize, "control-payload-size", 64, "control message bytes for mixed_moqt_shaped --json runs")
	flags.IntVar(&cfg.controlMessageCount, "control-message-count", 10, "control messages to send for mixed_moqt_shaped --json runs")
	flags.IntVar(&cfg.controlRate, "control-rate", 10, "target control messages per second for mixed_moqt_shaped --json runs")
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
	if err := validateUDPNetwork(cfg.udpNetwork); err != nil {
		return clientConfig{}, 0, err
	}
	if err := validateInitialPacketSize(cfg.initialSize); err != nil {
		return clientConfig{}, 0, err
	}
	if timeout <= 0 {
		return clientConfig{}, 0, errors.New("client --timeout must be positive")
	}
	if cfg.workload != streamPressureWorkload &&
		cfg.workload != datagramPressureWorkload &&
		cfg.workload != mixedMOQTShapedWorkload {
		return clientConfig{}, 0, errors.New("client --workload must be stream_pressure, datagram_pressure, or mixed_moqt_shaped")
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
	if cfg.datagramRate < 0 {
		return clientConfig{}, 0, errors.New("client --datagram-rate must be zero or positive")
	}
	if cfg.durationSeconds < 0 {
		return clientConfig{}, 0, errors.New("client --duration-seconds must be zero or positive")
	}
	if cfg.datagramRate > 0 && cfg.durationSeconds == 0 {
		return clientConfig{}, 0, errors.New("client --duration-seconds is required when --datagram-rate is set")
	}
	if cfg.datagramRate == 0 && cfg.durationSeconds > 0 {
		return clientConfig{}, 0, errors.New("client --datagram-rate is required when --duration-seconds is set")
	}
	if cfg.rateTolerance <= 0 || cfg.rateTolerance > 1 {
		return clientConfig{}, 0, errors.New("client --offered-rate-tolerance must be greater than 0 and at most 1")
	}
	if cfg.workload == mixedMOQTShapedWorkload && cfg.controlPayloadSize <= 0 {
		return clientConfig{}, 0, errors.New("client --control-payload-size must be positive")
	}
	if cfg.workload == mixedMOQTShapedWorkload && cfg.controlMessageCount <= 0 {
		return clientConfig{}, 0, errors.New("client --control-message-count must be positive")
	}
	if cfg.workload == mixedMOQTShapedWorkload && cfg.controlRate <= 0 {
		return clientConfig{}, 0, errors.New("client --control-rate must be positive")
	}

	return cfg, timeout, nil
}

func runServer(ctx context.Context, cfg serverConfig, ready chan<- string, evidenceOut io.Writer) error {
	cert, err := tls.LoadX509KeyPair(cfg.certFile, cfg.keyFile)
	if err != nil {
		return fmt.Errorf("load server certificate: %w", err)
	}

	udpNetwork, udpAddr, err := resolveListenUDPAddr(cfg.addr, cfg.udpNetwork)
	if err != nil {
		return err
	}
	udpConn, err := net.ListenUDP(udpNetwork, udpAddr)
	if err != nil {
		return fmt.Errorf("listen udp: %w", err)
	}
	defer udpConn.Close()

	listener, err := quic.Listen(udpConn, &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{cfg.alpn},
	}, newQUICConfig(cfg.initialSize))
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()

	if ready != nil {
		ready <- listener.Addr().String()
	}

	recorder := newServerRunEvidenceRecorder(evidenceOut, cfg.statsOutput)

	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}

			return fmt.Errorf("accept connection: %w", err)
		}

		go handleConnection(ctx, conn, recorder)
	}
}

func newServerConnectionStats(conn quic.Connection) *serverConnectionStats {
	return &serverConnectionStats{
		startedAt:  time.Now(),
		localAddr:  conn.LocalAddr().String(),
		remoteAddr: conn.RemoteAddr().String(),
		alpn:       conn.ConnectionState().TLS.NegotiatedProtocol,
	}
}

func handleConnection(ctx context.Context, conn quic.Connection, recorder *serverRunEvidenceRecorder) {
	stats := newServerConnectionStats(conn)
	var wg sync.WaitGroup
	var streamHandlers sync.WaitGroup
	var datagramStats datagramEchoStats

	wg.Add(3)

	go func() {
		defer wg.Done()
		acceptBidiStreams(ctx, conn, &streamHandlers, stats)
	}()

	go func() {
		defer wg.Done()
		acceptUniStreams(ctx, conn, &streamHandlers, stats)
	}()

	go func() {
		defer wg.Done()
		datagramStats = echoDatagrams(ctx, conn)
	}()

	wg.Wait()
	streamHandlers.Wait()

	stats.setDatagrams(datagramStats)
	stats.finish()

	if recorder != nil {
		if err := recorder.Record(stats.snapshot()); err != nil {
			fmt.Fprintf(os.Stderr, "record server run evidence: %v\n", err)
		}
	}
}

func (s *serverConnectionStats) recordBidiStreamAccepted() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.bidiStreamsAccepted++
}

func (s *serverConnectionStats) recordUniStreamAccepted() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.uniStreamsAccepted++
}

func (s *serverConnectionStats) recordStreamBytesReceived(count int64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.streamBytesReceived += count
	if s.firstStreamByteLatency == 0 {
		s.firstStreamByteLatency = time.Since(s.startedAt)
	}
}

func (s *serverConnectionStats) recordStreamBytesEchoed(count int64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.streamBytesEchoed += count
}

func (s *serverConnectionStats) recordStreamCompleted() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.streamsCompleted++
}

func (s *serverConnectionStats) recordStreamReceiveError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.streamReceiveErrCount++
	if s.streamReceiveErr == nil {
		s.streamReceiveErr = err
	}
}

func (s *serverConnectionStats) recordStreamSendError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.streamSendErrCount++
	if s.streamSendErr == nil {
		s.streamSendErr = err
	}
}

func (s *serverConnectionStats) setDatagrams(stats datagramEchoStats) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.datagrams = stats
}

func (s *serverConnectionStats) finish() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.finishedAt = time.Now()
}

func (s *serverConnectionStats) snapshot() serverConnectionStatsSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()

	return serverConnectionStatsSnapshot{
		startedAt:                 s.startedAt,
		finishedAt:                s.finishedAt,
		localAddr:                 s.localAddr,
		remoteAddr:                s.remoteAddr,
		alpn:                      s.alpn,
		datagramsReceived:         s.datagrams.datagramsReceived,
		datagramsEchoAccepted:     s.datagrams.datagramsEchoAccepted,
		datagramBytesReceived:     s.datagrams.bytesReceived,
		datagramBytesEchoAccepted: s.datagrams.bytesEchoAccepted,
		echoQueueCapacity:         s.datagrams.echoQueueCapacity,
		echoQueueMaxDepth:         s.datagrams.echoQueueMaxDepth,
		datagramReceiveErr:        s.datagrams.receiveErr,
		datagramSendErr:           s.datagrams.sendErr,
		firstDatagramLatency:      s.datagrams.firstDatagramLatency,
		bidiStreamsAccepted:       s.bidiStreamsAccepted,
		uniStreamsAccepted:        s.uniStreamsAccepted,
		streamsCompleted:          s.streamsCompleted,
		streamBytesReceived:       s.streamBytesReceived,
		streamBytesEchoed:         s.streamBytesEchoed,
		streamReceiveErrCount:     s.streamReceiveErrCount,
		streamSendErrCount:        s.streamSendErrCount,
		streamReceiveErr:          s.streamReceiveErr,
		streamSendErr:             s.streamSendErr,
		firstStreamByteLatency:    s.firstStreamByteLatency,
	}
}

func acceptBidiStreams(ctx context.Context, conn quic.Connection, streamHandlers *sync.WaitGroup, stats *serverConnectionStats) {
	for {
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			return
		}

		stats.recordBidiStreamAccepted()
		streamHandlers.Add(1)
		go func() {
			defer streamHandlers.Done()
			handleBidiEchoStream(stream, stats)
		}()
	}
}

func acceptUniStreams(ctx context.Context, conn quic.Connection, streamHandlers *sync.WaitGroup, stats *serverConnectionStats) {
	for {
		stream, err := conn.AcceptUniStream(ctx)
		if err != nil {
			return
		}

		stats.recordUniStreamAccepted()
		streamHandlers.Add(1)
		go func() {
			defer streamHandlers.Done()
			drainUniStream(stream, stats)
		}()
	}
}

func handleBidiEchoStream(stream quic.Stream, stats *serverConnectionStats) {
	if err := echoStream(stream, stats); err != nil {
		stream.CancelWrite(1)
		return
	}

	if err := stream.Close(); err != nil {
		stats.recordStreamSendError(err)
		return
	}

	stats.recordStreamCompleted()
}

func echoStream(stream quic.Stream, stats *serverConnectionStats) error {
	buffer := make([]byte, 32*1024)

	for {
		n, readErr := stream.Read(buffer)
		if n > 0 {
			stats.recordStreamBytesReceived(int64(n))
			written, err := writeFull(stream, buffer[:n])
			stats.recordStreamBytesEchoed(int64(written))
			if err != nil {
				stats.recordStreamSendError(err)
				return err
			}
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			stats.recordStreamReceiveError(readErr)
			return readErr
		}
	}
}

func drainUniStream(stream quic.ReceiveStream, stats *serverConnectionStats) {
	buffer := make([]byte, 32*1024)

	for {
		n, err := stream.Read(buffer)
		if n > 0 {
			stats.recordStreamBytesReceived(int64(n))
		}
		if err == io.EOF {
			stats.recordStreamCompleted()
			return
		}
		if err != nil {
			stats.recordStreamReceiveError(err)
			return
		}
	}
}

func echoDatagrams(ctx context.Context, conn datagramConn) (stats datagramEchoStats) {
	stats = datagramEchoStats{
		startedAt:         time.Now(),
		localAddr:         conn.LocalAddr().String(),
		remoteAddr:        conn.RemoteAddr().String(),
		echoQueueCapacity: datagramEchoQueueLen,
		echoQueueMaxDepth: 0,
	}
	defer func() {
		stats.finishedAt = time.Now()
	}()

	echoQueue := make(chan []byte, datagramEchoQueueLen)
	echoStats := make(chan datagramEchoStats, 1)

	go func() {
		echoStats <- sendDatagramEchoes(conn, echoQueue)
	}()

	for {
		datagram, err := conn.ReceiveDatagram(ctx)
		if err != nil {
			stats.receiveErr = err
			close(echoQueue)
			echo := <-echoStats
			stats.datagramsEchoAccepted = echo.datagramsEchoAccepted
			stats.bytesEchoAccepted = echo.bytesEchoAccepted
			stats.sendErr = echo.sendErr
			return
		}
		if stats.datagramsReceived == 0 {
			stats.firstDatagramLatency = time.Since(stats.startedAt)
		}
		stats.datagramsReceived++
		stats.bytesReceived += int64(len(datagram))

		echoQueue <- datagram
		if depth := len(echoQueue); depth > stats.echoQueueMaxDepth {
			stats.echoQueueMaxDepth = depth
		}
	}
}

func sendDatagramEchoes(conn datagramConn, echoQueue <-chan []byte) (stats datagramEchoStats) {
	for datagram := range echoQueue {
		if stats.sendErr != nil {
			continue
		}

		if err := conn.SendDatagram(datagram); err != nil {
			stats.sendErr = err
			continue
		}

		stats.datagramsEchoAccepted++
		stats.bytesEchoAccepted += int64(len(datagram))
	}

	return stats
}

func newServerRunEvidenceRecorder(stdout io.Writer, statsOutput string) *serverRunEvidenceRecorder {
	if stdout == nil && statsOutput == "" {
		return nil
	}

	return &serverRunEvidenceRecorder{
		stdout:      stdout,
		statsOutput: statsOutput,
	}
}

func (r *serverRunEvidenceRecorder) Record(stats serverConnectionStatsSnapshot) error {
	evidence := serverRunEvidenceFromSnapshot(r.sequence.Add(1), stats)

	r.mu.Lock()
	defer r.mu.Unlock()

	if r.stdout != nil {
		if err := json.NewEncoder(r.stdout).Encode(evidence); err != nil {
			return fmt.Errorf("write server run evidence stdout: %w", err)
		}
	}

	if r.statsOutput != "" {
		if err := appendServerRunEvidence(r.statsOutput, evidence); err != nil {
			return err
		}
	}

	return nil
}

func serverRunEvidenceFromSnapshot(sequence uint64, stats serverConnectionStatsSnapshot) serverRunEvidence {
	evidence := serverRunEvidence{
		SchemaVersion:             serverRunEvidenceSchema,
		RecordType:                serverRunEvidenceRecordType,
		Tool:                      "quicprobe",
		ReferenceImpl:             "quic-go",
		ReferenceVersion:          moduleVersion(quicGoModulePath),
		RunSequence:               sequence,
		StartedAt:                 stats.startedAt.UTC().Format(time.RFC3339Nano),
		FinishedAt:                stats.finishedAt.UTC().Format(time.RFC3339Nano),
		LocalAddr:                 stats.localAddr,
		RemoteAddr:                stats.remoteAddr,
		ALPN:                      stats.alpn,
		DurationMS:                durationMillis(stats.finishedAt.Sub(stats.startedAt)),
		BidiStreamSemantics:       "echo",
		UniStreamSemantics:        "drain",
		DatagramSemantics:         "echo",
		DatagramsReceived:         stats.datagramsReceived,
		DatagramsEchoAccepted:     stats.datagramsEchoAccepted,
		DatagramBytesReceived:     stats.datagramBytesReceived,
		DatagramBytesEchoAccepted: stats.datagramBytesEchoAccepted,
		BidiStreamsAccepted:       stats.bidiStreamsAccepted,
		UniStreamsAccepted:        stats.uniStreamsAccepted,
		StreamsCompleted:          stats.streamsCompleted,
		StreamBytesReceived:       stats.streamBytesReceived,
		StreamBytesEchoAccepted:   stats.streamBytesEchoed,
		StreamReceiveErrorCount:   stats.streamReceiveErrCount,
		StreamSendErrorCount:      stats.streamSendErrCount,
		EchoQueueCapacity:         stats.echoQueueCapacity,
		EchoQueueMaxDepth:         stats.echoQueueMaxDepth,
		FirstDatagramLatencyMS:    durationMillis(stats.firstDatagramLatency),
		FirstStreamByteLatencyMS:  durationMillis(stats.firstStreamByteLatency),
		ReceiverEvidenceComplete:  true,
	}

	if isUnexpectedEvidenceError(stats.datagramReceiveErr) {
		evidence.DatagramReceiveError = stats.datagramReceiveErr.Error()
	}
	if isUnexpectedEvidenceError(stats.datagramSendErr) {
		evidence.DatagramSendError = stats.datagramSendErr.Error()
	}
	if isUnexpectedEvidenceError(stats.streamReceiveErr) {
		evidence.StreamReceiveError = stats.streamReceiveErr.Error()
	}
	if isUnexpectedEvidenceError(stats.streamSendErr) {
		evidence.StreamSendError = stats.streamSendErr.Error()
	}

	evidence.ReceiverEvidenceComplete, evidence.ReceiverEvidenceFailureCause = receiverEvidenceStatus(stats)

	return evidence
}

func receiverEvidenceStatus(stats serverConnectionStatsSnapshot) (bool, string) {
	switch {
	case isUnexpectedEvidenceError(stats.datagramReceiveErr):
		return false, "datagram_receive_error"
	case isUnexpectedEvidenceError(stats.datagramSendErr):
		return false, "datagram_send_error"
	case isUnexpectedEvidenceError(stats.streamReceiveErr):
		return false, "stream_receive_error"
	case isUnexpectedEvidenceError(stats.streamSendErr):
		return false, "stream_send_error"
	default:
		return true, ""
	}
}

func isUnexpectedEvidenceError(err error) bool {
	if err == nil {
		return false
	}

	var appErr *quic.ApplicationError
	if errors.As(err, &appErr) && appErr.Remote && appErr.ErrorCode == 0 {
		return false
	}

	return true
}

func appendServerRunEvidence(path string, evidence serverRunEvidence) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open server evidence output: %w", err)
	}
	defer file.Close()

	return json.NewEncoder(file).Encode(evidence)
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

	udpNetwork, udpAddr, err := resolveRemoteUDPAddr(cfg.addr, cfg.udpNetwork)
	if err != nil {
		return err
	}
	udpConn, err := net.ListenUDP(udpNetwork, clientLocalUDPAddr(udpNetwork))
	if err != nil {
		return fmt.Errorf("listen udp: %w", err)
	}
	defer udpConn.Close()

	conn, err := quic.Dial(ctx, udpConn, udpAddr, &tls.Config{
		MinVersion: tls.VersionTLS13,
		RootCAs:    roots,
		ServerName: serverName,
		NextProtos: []string{cfg.alpn},
	}, newQUICConfig(cfg.initialSize))
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
	case mixedMOQTShapedWorkload:
		return runMixedMOQTShapedClient(ctx, cfg, conn, startedAt, handshakeLatency)
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

type mixedObjectStreamResult struct {
	bytesSent int64
	latencyMS float64
	err       error
}

type mixedControlResult struct {
	bytesSent     int64
	bytesReceived int64
	latenciesMS   []float64
	err           error
}

func runMixedMOQTShapedClient(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	startedAt time.Time,
	handshakeLatency time.Duration,
) (clientRunResult, error) {
	applicationStartedAt := time.Now()
	objectPayload := deterministicPayload(cfg.payloadSize)
	controlPayload := deterministicPayload(cfg.controlPayloadSize)
	firstByte := make(chan time.Duration, 1)
	objectResultc := make(chan mixedObjectStreamResult, cfg.streamCount)
	controlResultc := make(chan mixedControlResult, 1)

	for index := 0; index < cfg.streamCount; index++ {
		go func() {
			streamStartedAt := time.Now()
			sent, _, err := runUniPressureStream(ctx, cfg, conn, objectPayload)
			objectResultc <- mixedObjectStreamResult{
				bytesSent: sent,
				latencyMS: durationMillis(time.Since(streamStartedAt)),
				err:       err,
			}
		}()
	}

	go func() {
		controlResultc <- runMixedControlStream(
			ctx,
			cfg,
			conn,
			controlPayload,
			firstByte,
			applicationStartedAt,
		)
	}()

	var objectBytesSent int64
	objectLatencies := make([]float64, 0, cfg.streamCount)

	for index := 0; index < cfg.streamCount; index++ {
		result := <-objectResultc
		if result.err != nil {
			return clientRunResult{}, result.err
		}

		objectBytesSent += result.bytesSent
		objectLatencies = append(objectLatencies, result.latencyMS)
	}

	controlResult := <-controlResultc
	if controlResult.err != nil {
		return clientRunResult{}, controlResult.err
	}

	applicationDuration := time.Since(applicationStartedAt)
	finishedAt := time.Now()
	firstByteLatency := firstByteLatencyMS(firstByte)
	totalBytesSent := objectBytesSent + controlResult.bytesSent
	totalBytesReceived := controlResult.bytesReceived

	return clientRunResult{
		SchemaVersion:            "quicprobe-v1",
		RecordType:               "client_run",
		Tool:                     "quicprobe",
		ReferenceImpl:            "quic-go",
		ReferenceVersion:         moduleVersion(quicGoModulePath),
		StartedAt:                startedAt.UTC().Format(time.RFC3339Nano),
		FinishedAt:               finishedAt.UTC().Format(time.RFC3339Nano),
		RemoteAddr:               conn.RemoteAddr().String(),
		ALPN:                     conn.ConnectionState().TLS.NegotiatedProtocol,
		Workload:                 mixedMOQTShapedWorkload,
		StreamDirection:          "mixed",
		StreamCount:              cfg.streamCount,
		PayloadSizeBytes:         cfg.payloadSize,
		PayloadCount:             cfg.payloadCount,
		ControlPayloadSizeBytes:  cfg.controlPayloadSize,
		ControlMessageCount:      cfg.controlMessageCount,
		ControlMessagesPerSecond: float64(cfg.controlRate),
		ControlTrickleBPS:        controlTrickleBPS(cfg),
		BytesSent:                totalBytesSent,
		BytesReceived:            totalBytesReceived,
		HandshakeLatencyMS:       durationMillis(handshakeLatency),
		FirstByteLatencyMS:       firstByteLatency,
		ApplicationDurationMS:    durationMillis(applicationDuration),
		GoodputBPS:               throughputBPS(totalBytesSent, applicationDuration),
		SendRatePacketsPPS:       rate(cfg.streamCount*cfg.payloadCount+cfg.controlMessageCount, applicationDuration),
		StreamScheduling:         "mixed_control_bidi_object_uni",
		StreamLatencyMS:          latencySummary(objectLatencies),
		ControlLatencyMS:         latencySummary(controlResult.latenciesMS),
	}, nil
}

func runMixedControlStream(
	ctx context.Context,
	cfg clientConfig,
	conn quic.Connection,
	payload []byte,
	firstByte chan<- time.Duration,
	firstByteOrigin time.Time,
) mixedControlResult {
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return mixedControlResult{err: fmt.Errorf("open mixed control stream: %w", err)}
	}

	startedAt := time.Now()
	interval := time.Second / time.Duration(cfg.controlRate)
	latencies := make([]float64, 0, cfg.controlMessageCount)

	var bytesSent int64
	var bytesReceived int64

	for message := 1; message <= cfg.controlMessageCount; message++ {
		deadline := pacedDatagramDeadline(startedAt, interval, message)
		if err := waitUntil(ctx, deadline); err != nil {
			return mixedControlResult{bytesSent: bytesSent, bytesReceived: bytesReceived, latenciesMS: latencies, err: err}
		}

		sentAt := time.Now()
		n, err := writeFull(stream, payload)
		bytesSent += int64(n)
		if err != nil {
			return mixedControlResult{bytesSent: bytesSent, bytesReceived: bytesReceived, latenciesMS: latencies, err: fmt.Errorf("write mixed control stream: %w", err)}
		}

		received, err := readControlEcho(stream, payload)
		bytesReceived += int64(received)
		if err != nil {
			return mixedControlResult{bytesSent: bytesSent, bytesReceived: bytesReceived, latenciesMS: latencies, err: err}
		}

		if len(latencies) == 0 {
			notifyFirstByte(firstByte, time.Since(firstByteOrigin))
		}

		latencies = append(latencies, durationMillis(time.Since(sentAt)))
	}

	if err := stream.Close(); err != nil {
		return mixedControlResult{bytesSent: bytesSent, bytesReceived: bytesReceived, latenciesMS: latencies, err: fmt.Errorf("close mixed control stream: %w", err)}
	}

	return mixedControlResult{bytesSent: bytesSent, bytesReceived: bytesReceived, latenciesMS: latencies}
}

func readControlEcho(reader io.Reader, payload []byte) (int, error) {
	echo := make([]byte, len(payload))
	n, err := io.ReadFull(reader, echo)
	if err != nil {
		return n, fmt.Errorf("read mixed control echo: %w", err)
	}
	if !matchesPayload(echo, payload, 0) {
		return n, errors.New("mixed control echo payload mismatch")
	}

	return n, nil
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
	offered := effectiveDatagramCount(cfg)
	mode := datagramMode(cfg)
	receiveResultc := make(chan datagramReceiveResult, 1)

	go func() {
		received, firstByteLatency, latencies, err := receiveDatagramEchoes(ctx, conn, offered, applicationStartedAt)

		receiveResultc <- datagramReceiveResult{
			received:         received,
			firstByteLatency: firstByteLatency,
			latencies:        latencies,
			err:              err,
		}
	}()

	sendResult, err := sendDatagrams(ctx, conn, cfg, offered)
	if err != nil {
		return clientRunResult{}, err
	}

	receiveResult := <-receiveResultc
	if receiveResult.err != nil {
		return clientRunResult{}, receiveResult.err
	}

	applicationDuration := time.Since(applicationStartedAt)
	finishedAt := time.Now()
	drops := offered - receiveResult.received
	bytesSent := int64(sendResult.accepted * cfg.datagramSize)
	bytesReceived := int64(receiveResult.received * cfg.datagramSize)
	sendRate := rate(sendResult.accepted, sendResult.duration)
	offeredRateRatio := targetRateRatio(sendRate, cfg)

	return clientRunResult{
		SchemaVersion:                   "quicprobe-v1",
		RecordType:                      "client_run",
		Tool:                            "quicprobe",
		ReferenceImpl:                   "quic-go",
		ReferenceVersion:                moduleVersion(quicGoModulePath),
		StartedAt:                       startedAt.UTC().Format(time.RFC3339Nano),
		FinishedAt:                      finishedAt.UTC().Format(time.RFC3339Nano),
		RemoteAddr:                      conn.RemoteAddr().String(),
		ALPN:                            conn.ConnectionState().TLS.NegotiatedProtocol,
		Workload:                        datagramPressureWorkload,
		PayloadSizeBytes:                cfg.datagramSize,
		DatagramSizeBytes:               cfg.datagramSize,
		DatagramCount:                   offered,
		DatagramMode:                    mode,
		TargetDatagramPPS:               targetDatagramRate(cfg),
		TargetDurationSeconds:           targetDurationSeconds(cfg),
		OfferedRateRatio:                offeredRateRatio,
		OfferedRateTolerance:            cfg.rateTolerance,
		OfferedRateValid:                offeredRateValid(offeredRateRatio, cfg),
		DatagramsOffered:                offered,
		DatagramsAccepted:               sendResult.accepted,
		DatagramsReceived:               receiveResult.received,
		DatagramDeliveryRatio:           ratio(receiveResult.received, offered),
		DatagramDropCount:               drops,
		BytesSent:                       bytesSent,
		BytesReceived:                   bytesReceived,
		HandshakeLatencyMS:              durationMillis(handshakeLatency),
		FirstByteLatencyMS:              receiveResult.firstByteLatency,
		ApplicationDurationMS:           durationMillis(applicationDuration),
		SendDurationMS:                  durationMillis(sendResult.duration),
		TargetSendDurationMS:            durationMillis(sendResult.targetDuration),
		ScheduledSendSpanMS:             durationMillis(sendResult.scheduledSpan),
		OfferedLoadBPS:                  offeredLoadBPS(cfg),
		GoodputBPS:                      throughputBPS(bytesReceived, applicationDuration),
		SendRateDatagramPPS:             sendRate,
		SendPacingLateCount:             sendResult.pacingLateCount,
		SendPacingLagMS:                 sendPacingLagSummary(sendResult),
		SendDatagramCallSlowCount:       sendResult.sendCallSlowCount,
		SendDatagramCallSlowThresholdMS: durationMillis(pacedSpinThreshold),
		SendDatagramCallTotalMS:         durationMillis(sendResult.sendCallTotal),
		SendDatagramCallMS:              sendDatagramCallSummary(sendResult),
		DatagramLatencyMS:               latencySummary(receiveResult.latencies),
	}, nil
}

func sendDatagrams(ctx context.Context, conn quic.Connection, cfg clientConfig, count int) (datagramSendResult, error) {
	if cfg.datagramRate > 0 {
		return sendDatagramPaced(ctx, conn, cfg, count)
	}

	return sendDatagramBurst(conn, cfg, count)
}

func sendDatagramBurst(conn quic.Connection, cfg clientConfig, count int) (datagramSendResult, error) {
	startedAt := time.Now()
	result := datagramSendResult{
		sendCallMillis: make([]float64, 0, count),
	}

	for sequence := 1; sequence <= count; sequence++ {
		payload := datagramPayload(uint64(sequence), cfg.datagramSize, time.Now())
		if err := sendDatagramWithTiming(conn, payload, &result); err != nil {
			result.accepted = sequence - 1
			result.duration = time.Since(startedAt)
			return result, fmt.Errorf("send datagram %d: %w", sequence, err)
		}
	}

	result.accepted = count
	result.duration = time.Since(startedAt)
	return result, nil
}

func sendDatagramPaced(ctx context.Context, conn quic.Connection, cfg clientConfig, count int) (datagramSendResult, error) {
	startedAt := time.Now()
	interval := time.Second / time.Duration(cfg.datagramRate)
	result := datagramSendResult{
		targetDuration:  targetPacedSendDuration(count, cfg),
		scheduledSpan:   scheduledPacedSendSpan(count, interval),
		pacingLagMillis: make([]float64, 0, count),
		sendCallMillis:  make([]float64, 0, count),
	}

	for sequence := 1; sequence <= count; sequence++ {
		deadline := pacedDatagramDeadline(startedAt, interval, sequence)
		if err := waitUntil(ctx, deadline); err != nil {
			result.accepted = sequence - 1
			result.duration = time.Since(startedAt)
			return result, nil
		}

		sendAt := time.Now()
		lag := sendAt.Sub(deadline)
		if lag < 0 {
			lag = 0
		}
		if lag > pacedSpinThreshold {
			result.pacingLateCount++
		}
		result.pacingLagMillis = append(result.pacingLagMillis, durationMillis(lag))

		payload := datagramPayload(uint64(sequence), cfg.datagramSize, sendAt)
		if err := sendDatagramWithTiming(conn, payload, &result); err != nil {
			result.accepted = sequence - 1
			result.duration = time.Since(startedAt)
			return result, fmt.Errorf("send datagram %d: %w", sequence, err)
		}
	}

	result.accepted = count
	result.duration = time.Since(startedAt)
	return result, nil
}

func sendDatagramWithTiming(conn quic.Connection, payload []byte, result *datagramSendResult) error {
	startedAt := time.Now()
	err := conn.SendDatagram(payload)
	duration := time.Since(startedAt)

	result.sendCallMillis = append(result.sendCallMillis, durationMillis(duration))
	result.sendCallTotal += duration
	if duration > pacedSpinThreshold {
		result.sendCallSlowCount++
	}

	return err
}

func pacedDatagramDeadline(startedAt time.Time, interval time.Duration, sequence int) time.Time {
	return startedAt.Add(time.Duration(sequence-1) * interval)
}

func targetPacedSendDuration(count int, cfg clientConfig) time.Duration {
	if cfg.datagramRate <= 0 || count <= 0 {
		return 0
	}

	return time.Duration(count) * time.Second / time.Duration(cfg.datagramRate)
}

func scheduledPacedSendSpan(count int, interval time.Duration) time.Duration {
	if count <= 1 {
		return 0
	}

	return time.Duration(count-1) * interval
}

func sendPacingLagSummary(result datagramSendResult) map[string]float64 {
	if len(result.pacingLagMillis) == 0 {
		return nil
	}

	return latencySummary(result.pacingLagMillis)
}

func sendDatagramCallSummary(result datagramSendResult) map[string]float64 {
	if len(result.sendCallMillis) == 0 {
		return nil
	}

	sorted := append([]float64(nil), result.sendCallMillis...)
	sort.Float64s(sorted)

	return map[string]float64{
		"p50":  percentile(sorted, 0.50),
		"p95":  percentile(sorted, 0.95),
		"p99":  percentile(sorted, 0.99),
		"p999": percentile(sorted, 0.999),
		"max":  sorted[len(sorted)-1],
	}
}

func waitUntil(ctx context.Context, deadline time.Time) error {
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil
		}

		if remaining <= pacedSpinThreshold {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
				runtime.Gosched()
				continue
			}
		}

		timer := time.NewTimer(remaining - pacedSpinThreshold)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func effectiveDatagramCount(cfg clientConfig) int {
	if cfg.datagramRate > 0 {
		return cfg.datagramRate * cfg.durationSeconds
	}

	return cfg.datagramCount
}

func datagramMode(cfg clientConfig) string {
	if cfg.datagramRate > 0 {
		return "paced"
	}

	return "burst"
}

func targetDatagramRate(cfg clientConfig) float64 {
	if cfg.datagramRate > 0 {
		return float64(cfg.datagramRate)
	}

	return 0
}

func targetDurationSeconds(cfg clientConfig) int {
	if cfg.datagramRate > 0 {
		return cfg.durationSeconds
	}

	return 0
}

func targetRateRatio(sendRate float64, cfg clientConfig) float64 {
	target := targetDatagramRate(cfg)
	if target <= 0 || sendRate <= 0 {
		return 0
	}

	return sendRate / target
}

func offeredRateValid(ratio float64, cfg clientConfig) bool {
	if cfg.datagramRate == 0 {
		return true
	}

	return ratio >= cfg.rateTolerance
}

func offeredLoadBPS(cfg clientConfig) float64 {
	if cfg.datagramRate > 0 {
		return float64(cfg.datagramRate * cfg.datagramSize * 8)
	}

	return 0
}

func controlTrickleBPS(cfg clientConfig) float64 {
	return float64(cfg.controlRate * cfg.controlPayloadSize * 8)
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

func validateUDPNetwork(network string) error {
	switch normalizeUDPNetwork(network) {
	case udpNetworkAuto, "udp", "udp4", "udp6":
		return nil
	default:
		return fmt.Errorf("invalid UDP network %q; expected auto, udp, udp4, or udp6", network)
	}
}

func validateInitialPacketSize(size int) error {
	if size == 0 {
		return nil
	}
	if size < 1200 || size > 1452 {
		return fmt.Errorf("invalid initial packet size %d; expected 0 or a value from 1200 through 1452", size)
	}

	return nil
}

func newQUICConfig(initialPacketSize int) *quic.Config {
	cfg := &quic.Config{EnableDatagrams: true}
	if initialPacketSize > 0 {
		cfg.InitialPacketSize = uint16(initialPacketSize)
	}

	return cfg
}

func resolveListenUDPAddr(addr string, requestedNetwork string) (string, *net.UDPAddr, error) {
	network := normalizeUDPNetwork(requestedNetwork)
	if network == udpNetworkAuto {
		network = "udp"
		host, _, err := net.SplitHostPort(addr)
		if err == nil && host != "" {
			if ip := net.ParseIP(host); ip != nil {
				if ip.To4() != nil {
					network = "udp4"
				} else {
					network = "udp6"
				}
			}
		}
	}

	udpAddr, err := net.ResolveUDPAddr(network, addr)
	if err != nil {
		return "", nil, fmt.Errorf("resolve UDP listen address: %w", err)
	}

	return network, udpAddr, nil
}

func resolveRemoteUDPAddr(addr string, requestedNetwork string) (string, *net.UDPAddr, error) {
	requestedNetwork = normalizeUDPNetwork(requestedNetwork)
	if requestedNetwork != udpNetworkAuto {
		udpAddr, err := net.ResolveUDPAddr(requestedNetwork, addr)
		if err != nil {
			return "", nil, fmt.Errorf("resolve UDP remote address: %w", err)
		}

		return requestedNetwork, udpAddr, nil
	}

	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return "", nil, fmt.Errorf("resolve UDP remote address: %w", err)
	}

	network := "udp"
	if udpAddr.IP.To4() != nil {
		network = "udp4"
	} else if udpAddr.IP.To16() != nil {
		network = "udp6"
	}

	if network != "udp" {
		udpAddr, err = net.ResolveUDPAddr(network, addr)
		if err != nil {
			return "", nil, fmt.Errorf("resolve UDP remote address: %w", err)
		}
	}

	return network, udpAddr, nil
}

func normalizeUDPNetwork(network string) string {
	if network == "" {
		return udpNetworkAuto
	}

	return network
}

func clientLocalUDPAddr(network string) *net.UDPAddr {
	switch network {
	case "udp4":
		return &net.UDPAddr{IP: net.IPv4zero, Port: 0}
	case "udp6":
		return &net.UDPAddr{IP: net.IPv6zero, Port: 0}
	default:
		return &net.UDPAddr{Port: 0}
	}
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
