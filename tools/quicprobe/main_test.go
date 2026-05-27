package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClientServerBidiEcho(t *testing.T) {
	t.Parallel()

	certs := writeTestCerts(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:     "127.0.0.1:0",
			certFile: certs.serverCert,
			keyFile:  certs.serverKey,
			alpn:     "moqx-test",
		}, ready)
	}()

	addr := awaitServerReady(t, ready, errc)
	var output strings.Builder

	clientCtx, clientCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer clientCancel()

	if err := runClient(clientCtx, clientConfig{
		addr:       addr,
		caFile:     certs.caCert,
		alpn:       "moqx-test",
		serverName: "localhost",
		bidiEcho:   "hello from quicprobe",
	}, &output); err != nil {
		t.Fatalf("runClient() error = %v", err)
	}

	if got, want := output.String(), "hello from quicprobe"; got != want {
		t.Fatalf("echo output = %q, want %q", got, want)
	}

	cancel()
	select {
	case err := <-errc:
		if err != nil && err != context.Canceled {
			t.Fatalf("runServer() after cancel error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestClientServerJSONStreamPressure(t *testing.T) {
	t.Parallel()

	certs := writeTestCerts(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:     "127.0.0.1:0",
			certFile: certs.serverCert,
			keyFile:  certs.serverKey,
			alpn:     "moqx-test",
		}, ready)
	}()

	addr := awaitServerReady(t, ready, errc)
	var output strings.Builder

	clientCtx, clientCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer clientCancel()

	err := runClient(clientCtx, clientConfig{
		addr:            addr,
		caFile:          certs.caCert,
		alpn:            "moqx-test",
		serverName:      "localhost",
		jsonOutput:      true,
		streamDirection: "bidirectional",
		streamCount:     2,
		payloadSize:     128,
		payloadCount:    3,
	}, &output)
	if err != nil {
		t.Fatalf("runClient() error = %v", err)
	}

	var result clientRunResult
	if err := json.Unmarshal([]byte(output.String()), &result); err != nil {
		t.Fatalf("JSON output did not decode: %v\n%s", err, output.String())
	}

	assertClientRunResult(t, result, "bidirectional", 2, 128, 3)

	cancel()
	select {
	case err := <-errc:
		if err != nil && err != context.Canceled {
			t.Fatalf("runServer() after cancel error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestClientServerJSONUnidirectionalStreamPressure(t *testing.T) {
	t.Parallel()

	certs := writeTestCerts(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:     "127.0.0.1:0",
			certFile: certs.serverCert,
			keyFile:  certs.serverKey,
			alpn:     "moqx-test",
		}, ready)
	}()

	addr := awaitServerReady(t, ready, errc)
	var output strings.Builder

	clientCtx, clientCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer clientCancel()

	err := runClient(clientCtx, clientConfig{
		addr:            addr,
		caFile:          certs.caCert,
		alpn:            "moqx-test",
		serverName:      "localhost",
		jsonOutput:      true,
		streamDirection: "unidirectional",
		streamCount:     2,
		payloadSize:     128,
		payloadCount:    3,
	}, &output)
	if err != nil {
		t.Fatalf("runClient() error = %v", err)
	}

	var result clientRunResult
	if err := json.Unmarshal([]byte(output.String()), &result); err != nil {
		t.Fatalf("JSON output did not decode: %v\n%s", err, output.String())
	}

	assertClientRunResult(t, result, "unidirectional", 2, 128, 3)

	cancel()
	select {
	case err := <-errc:
		if err != nil && err != context.Canceled {
			t.Fatalf("runServer() after cancel error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestClientServerJSONMixedMOQTShapedPressure(t *testing.T) {
	t.Parallel()

	certs := writeTestCerts(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:     "127.0.0.1:0",
			certFile: certs.serverCert,
			keyFile:  certs.serverKey,
			alpn:     "moqx-test",
		}, ready)
	}()

	addr := awaitServerReady(t, ready, errc)
	var output strings.Builder

	clientCtx, clientCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer clientCancel()

	err := runClient(clientCtx, clientConfig{
		addr:                addr,
		caFile:              certs.caCert,
		alpn:                "moqx-test",
		serverName:          "localhost",
		jsonOutput:          true,
		workload:            mixedMOQTShapedWorkload,
		streamCount:         2,
		payloadSize:         128,
		payloadCount:        3,
		controlPayloadSize:  32,
		controlMessageCount: 3,
		controlRate:         20,
	}, &output)
	if err != nil {
		t.Fatalf("runClient() error = %v", err)
	}

	var result clientRunResult
	if err := json.Unmarshal([]byte(output.String()), &result); err != nil {
		t.Fatalf("JSON output did not decode: %v\n%s", err, output.String())
	}

	expectedObjectBytes := int64(2 * 128 * 3)
	expectedControlBytes := int64(3 * 32)
	expectedBytesSent := expectedObjectBytes + expectedControlBytes

	if result.Workload != mixedMOQTShapedWorkload {
		t.Fatalf("workload = %q, want %s", result.Workload, mixedMOQTShapedWorkload)
	}
	if result.StreamDirection != "mixed" {
		t.Fatalf("stream_direction = %q, want mixed", result.StreamDirection)
	}
	if result.StreamCount != 2 {
		t.Fatalf("stream_count = %d, want 2", result.StreamCount)
	}
	if result.PayloadSizeBytes != 128 {
		t.Fatalf("payload_size_bytes = %d, want 128", result.PayloadSizeBytes)
	}
	if result.PayloadCount != 3 {
		t.Fatalf("payload_count = %d, want 3", result.PayloadCount)
	}
	if result.ControlPayloadSizeBytes != 32 {
		t.Fatalf("control_payload_size_bytes = %d, want 32", result.ControlPayloadSizeBytes)
	}
	if result.ControlMessageCount != 3 {
		t.Fatalf("control_message_count = %d, want 3", result.ControlMessageCount)
	}
	if result.ControlMessagesPerSecond != 20 {
		t.Fatalf("control_messages_per_second = %f, want 20", result.ControlMessagesPerSecond)
	}
	if result.ControlTrickleBPS != 5120 {
		t.Fatalf("control_trickle_bps = %f, want 5120", result.ControlTrickleBPS)
	}
	if result.BytesSent != expectedBytesSent {
		t.Fatalf("bytes_sent = %d, want %d", result.BytesSent, expectedBytesSent)
	}
	if result.BytesReceived != expectedControlBytes {
		t.Fatalf("bytes_received = %d, want %d", result.BytesReceived, expectedControlBytes)
	}
	if result.FirstByteLatencyMS == nil {
		t.Fatal("first_byte_latency_ms = nil, want measured control latency")
	}
	if result.ControlLatencyMS["p99"] <= 0 {
		t.Fatalf("control_latency_ms = %#v, want p99 > 0", result.ControlLatencyMS)
	}

	cancel()
	select {
	case err := <-errc:
		if err != nil && err != context.Canceled {
			t.Fatalf("runServer() after cancel error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestClientServerJSONDatagramPressure(t *testing.T) {
	t.Parallel()

	certs := writeTestCerts(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:     "127.0.0.1:0",
			certFile: certs.serverCert,
			keyFile:  certs.serverKey,
			alpn:     "moqx-test",
		}, ready)
	}()

	addr := awaitServerReady(t, ready, errc)
	var output strings.Builder

	clientCtx, clientCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer clientCancel()

	err := runClient(clientCtx, clientConfig{
		addr:          addr,
		caFile:        certs.caCert,
		alpn:          "moqx-test",
		serverName:    "localhost",
		jsonOutput:    true,
		workload:      datagramPressureWorkload,
		datagramSize:  64,
		datagramCount: 4,
	}, &output)
	if err != nil {
		t.Fatalf("runClient() error = %v", err)
	}

	var result clientRunResult
	if err := json.Unmarshal([]byte(output.String()), &result); err != nil {
		t.Fatalf("JSON output did not decode: %v\n%s", err, output.String())
	}

	assertDatagramRunResult(t, result, 64, 4)

	cancel()
	select {
	case err := <-errc:
		if err != nil && err != context.Canceled {
			t.Fatalf("runServer() after cancel error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestClientServerJSONPacedDatagramPressure(t *testing.T) {
	t.Parallel()

	certs := writeTestCerts(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:     "127.0.0.1:0",
			certFile: certs.serverCert,
			keyFile:  certs.serverKey,
			alpn:     "moqx-test",
		}, ready)
	}()

	addr := awaitServerReady(t, ready, errc)
	var output strings.Builder

	clientCtx, clientCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer clientCancel()

	err := runClient(clientCtx, clientConfig{
		addr:            addr,
		caFile:          certs.caCert,
		alpn:            "moqx-test",
		serverName:      "localhost",
		jsonOutput:      true,
		workload:        datagramPressureWorkload,
		datagramSize:    64,
		datagramCount:   999,
		datagramRate:    20,
		durationSeconds: 1,
		rateTolerance:   0.95,
	}, &output)
	if err != nil {
		t.Fatalf("runClient() error = %v", err)
	}

	var result clientRunResult
	if err := json.Unmarshal([]byte(output.String()), &result); err != nil {
		t.Fatalf("JSON output did not decode: %v\n%s", err, output.String())
	}

	assertDatagramRunResult(t, result, 64, 20)
	if result.DatagramMode != "paced" {
		t.Fatalf("datagram_mode = %q, want paced", result.DatagramMode)
	}
	if result.TargetDatagramPPS != 20 {
		t.Fatalf("target_datagrams_per_second = %f, want 20", result.TargetDatagramPPS)
	}
	if result.TargetDurationSeconds != 1 {
		t.Fatalf("target_duration_seconds = %d, want 1", result.TargetDurationSeconds)
	}
	if !result.OfferedRateValid {
		t.Fatalf("offered_rate_valid = false, ratio=%f", result.OfferedRateRatio)
	}
	if result.OfferedRateTolerance != 0.95 {
		t.Fatalf("offered_rate_tolerance = %f, want 0.95", result.OfferedRateTolerance)
	}
	if result.SendDurationMS <= 0 {
		t.Fatalf("send_duration_ms = %f, want positive", result.SendDurationMS)
	}
	if result.TargetSendDurationMS != 1000 {
		t.Fatalf("target_send_duration_ms = %f, want 1000", result.TargetSendDurationMS)
	}
	if result.ScheduledSendSpanMS != 950 {
		t.Fatalf("scheduled_send_span_ms = %f, want 950", result.ScheduledSendSpanMS)
	}
	if _, ok := result.SendPacingLagMS["p99"]; !ok {
		t.Fatalf("send pacing lag summary = %#v, want p99", result.SendPacingLagMS)
	}

	cancel()
	select {
	case err := <-errc:
		if err != nil && err != context.Canceled {
			t.Fatalf("runServer() after cancel error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after context cancellation")
	}
}

func TestPacedDatagramDeadlineUsesAbsoluteSchedule(t *testing.T) {
	startedAt := time.Unix(100, 0)
	interval := 250 * time.Microsecond

	tests := []struct {
		sequence int
		want     time.Time
	}{
		{sequence: 1, want: startedAt},
		{sequence: 2, want: startedAt.Add(250 * time.Microsecond)},
		{sequence: 5, want: startedAt.Add(time.Millisecond)},
	}

	for _, test := range tests {
		if got := pacedDatagramDeadline(startedAt, interval, test.sequence); !got.Equal(test.want) {
			t.Fatalf("sequence %d deadline = %v, want %v", test.sequence, got, test.want)
		}
	}
}

func TestOfferedRateValidRequiresToleranceForPacedDatagrams(t *testing.T) {
	cfg := clientConfig{datagramRate: 1000, durationSeconds: 1, rateTolerance: 0.95}

	if offeredRateValid(0.94, cfg) {
		t.Fatal("offeredRateValid(0.94) = true, want false")
	}
	if !offeredRateValid(0.95, cfg) {
		t.Fatal("offeredRateValid(0.95) = false, want true")
	}
	if !offeredRateValid(0, clientConfig{}) {
		t.Fatal("burst offeredRateValid = false, want true")
	}
}

func assertClientRunResult(
	t *testing.T,
	result clientRunResult,
	direction string,
	streamCount int,
	payloadSize int,
	payloadCount int,
) {
	t.Helper()

	expectedBytes := int64(streamCount * payloadSize * payloadCount)
	if result.SchemaVersion != "quicprobe-v1" {
		t.Fatalf("schema_version = %q, want quicprobe-v1", result.SchemaVersion)
	}
	if result.RecordType != "client_run" {
		t.Fatalf("record_type = %q, want client_run", result.RecordType)
	}
	if result.ALPN != "moqx-test" {
		t.Fatalf("alpn = %q, want moqx-test", result.ALPN)
	}
	if result.Workload != streamPressureWorkload {
		t.Fatalf("workload = %q, want %s", result.Workload, streamPressureWorkload)
	}
	if result.StreamDirection != direction {
		t.Fatalf("stream_direction = %q, want %s", result.StreamDirection, direction)
	}
	if result.StreamCount != streamCount {
		t.Fatalf("stream_count = %d, want %d", result.StreamCount, streamCount)
	}
	if result.PayloadSizeBytes != payloadSize {
		t.Fatalf("payload_size_bytes = %d, want %d", result.PayloadSizeBytes, payloadSize)
	}
	if result.PayloadCount != payloadCount {
		t.Fatalf("payload_count = %d, want %d", result.PayloadCount, payloadCount)
	}
	if result.BytesSent != expectedBytes {
		t.Fatalf("bytes_sent = %d, want %d", result.BytesSent, expectedBytes)
	}
	expectedReceived := expectedBytes
	if direction == "unidirectional" {
		expectedReceived = 0
	}
	if result.BytesReceived != expectedReceived {
		t.Fatalf("bytes_received = %d, want %d", result.BytesReceived, expectedReceived)
	}
	if direction == "bidirectional" && result.FirstByteLatencyMS == nil {
		t.Fatal("first_byte_latency_ms = nil, want measured value")
	}
	if direction == "unidirectional" && result.FirstByteLatencyMS != nil {
		t.Fatalf("first_byte_latency_ms = %v, want nil", *result.FirstByteLatencyMS)
	}
	if result.GoodputBPS <= 0 {
		t.Fatalf("goodput_bps = %f, want positive", result.GoodputBPS)
	}
	if _, ok := result.StreamLatencyMS["p50"]; !ok {
		t.Fatalf("stream latency summary = %#v, want p50", result.StreamLatencyMS)
	}
}

func assertDatagramRunResult(t *testing.T, result clientRunResult, datagramSize int, datagramCount int) {
	t.Helper()

	expectedBytes := int64(datagramSize * datagramCount)
	if result.SchemaVersion != "quicprobe-v1" {
		t.Fatalf("schema_version = %q, want quicprobe-v1", result.SchemaVersion)
	}
	if result.RecordType != "client_run" {
		t.Fatalf("record_type = %q, want client_run", result.RecordType)
	}
	if result.ALPN != "moqx-test" {
		t.Fatalf("alpn = %q, want moqx-test", result.ALPN)
	}
	if result.Workload != datagramPressureWorkload {
		t.Fatalf("workload = %q, want %s", result.Workload, datagramPressureWorkload)
	}
	if result.DatagramSizeBytes != datagramSize {
		t.Fatalf("datagram_size_bytes = %d, want %d", result.DatagramSizeBytes, datagramSize)
	}
	if result.DatagramCount != datagramCount {
		t.Fatalf("datagram_count = %d, want %d", result.DatagramCount, datagramCount)
	}
	if result.DatagramMode == "" {
		t.Fatal("datagram_mode = empty, want burst or paced")
	}
	if result.DatagramsOffered != datagramCount {
		t.Fatalf("datagrams_offered = %d, want %d", result.DatagramsOffered, datagramCount)
	}
	if result.DatagramsAccepted != datagramCount {
		t.Fatalf("datagrams_accepted = %d, want %d", result.DatagramsAccepted, datagramCount)
	}
	if result.DatagramsReceived != datagramCount {
		t.Fatalf("datagrams_received = %d, want %d", result.DatagramsReceived, datagramCount)
	}
	if result.DatagramDropCount != 0 {
		t.Fatalf("datagram_drop_count = %d, want 0", result.DatagramDropCount)
	}
	if result.DatagramDeliveryRatio != 1.0 {
		t.Fatalf("datagram_delivery_ratio = %f, want 1.0", result.DatagramDeliveryRatio)
	}
	if result.BytesSent != expectedBytes {
		t.Fatalf("bytes_sent = %d, want %d", result.BytesSent, expectedBytes)
	}
	if result.BytesReceived != expectedBytes {
		t.Fatalf("bytes_received = %d, want %d", result.BytesReceived, expectedBytes)
	}
	if result.FirstByteLatencyMS == nil {
		t.Fatal("first_byte_latency_ms = nil, want measured value")
	}
	if result.GoodputBPS <= 0 {
		t.Fatalf("goodput_bps = %f, want positive", result.GoodputBPS)
	}
	if result.SendDurationMS <= 0 {
		t.Fatalf("send_duration_ms = %f, want positive", result.SendDurationMS)
	}
	if result.SendRateDatagramPPS <= 0 {
		t.Fatalf("send_rate_datagrams_per_second = %f, want positive", result.SendRateDatagramPPS)
	}
	if _, ok := result.DatagramLatencyMS["p50"]; !ok {
		t.Fatalf("datagram latency summary = %#v, want p50", result.DatagramLatencyMS)
	}
}

func awaitServerReady(t *testing.T, ready <-chan string, errc <-chan error) string {
	t.Helper()

	select {
	case addr := <-ready:
		return addr
	case err := <-errc:
		t.Fatalf("runServer() startup error = %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("server did not become ready")
	}

	return ""
}

type testCerts struct {
	caCert     string
	serverCert string
	serverKey  string
}

func writeTestCerts(t *testing.T) testCerts {
	t.Helper()

	dir := t.TempDir()
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "moqx integration test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}

	serverKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}

	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &serverKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}

	caCert := filepath.Join(dir, "ca.pem")
	serverCert := filepath.Join(dir, "server.pem")
	serverKeyFile := filepath.Join(dir, "server-key.pem")

	writePEM(t, caCert, "CERTIFICATE", caDER)
	writePEM(t, serverCert, "CERTIFICATE", serverDER)
	writePEM(t, serverKeyFile, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(serverKey))

	return testCerts{caCert: caCert, serverCert: serverCert, serverKey: serverKeyFile}
}

func writePEM(t *testing.T, path string, typ string, der []byte) {
	t.Helper()

	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	if err := pem.Encode(file, &pem.Block{Type: typ, Bytes: der}); err != nil {
		t.Fatal(err)
	}
}
