package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	quic "github.com/quic-go/quic-go"
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
		}, ready, nil)
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

func TestResolveRemoteUDPAddrAutoUsesUDP4ForIPv4(t *testing.T) {
	t.Parallel()

	network, udpAddr, err := resolveRemoteUDPAddr("192.0.2.10:55433", udpNetworkAuto)
	if err != nil {
		t.Fatalf("resolveRemoteUDPAddr() error = %v", err)
	}

	if network != "udp4" {
		t.Fatalf("network = %q, want udp4", network)
	}
	if got, want := udpAddr.String(), "192.0.2.10:55433"; got != want {
		t.Fatalf("resolved address = %q, want %q", got, want)
	}
}

func TestResolveListenUDPAddrAutoKeepsWildcardNetwork(t *testing.T) {
	t.Parallel()

	network, _, err := resolveListenUDPAddr(":55433", udpNetworkAuto)
	if err != nil {
		t.Fatalf("resolveListenUDPAddr() error = %v", err)
	}

	if network != "udp" {
		t.Fatalf("network = %q, want udp", network)
	}
}

func TestResolveListenUDPAddrAutoUsesUDP4ForIPv4Bind(t *testing.T) {
	t.Parallel()

	network, udpAddr, err := resolveListenUDPAddr("127.0.0.1:0", udpNetworkAuto)
	if err != nil {
		t.Fatalf("resolveListenUDPAddr() error = %v", err)
	}

	if network != "udp4" {
		t.Fatalf("network = %q, want udp4", network)
	}
	if got := udpAddr.IP.String(); got != "127.0.0.1" {
		t.Fatalf("resolved IP = %q, want 127.0.0.1", got)
	}
}

func TestValidateInitialPacketSize(t *testing.T) {
	t.Parallel()

	for _, size := range []int{0, 1200, 1452} {
		if err := validateInitialPacketSize(size); err != nil {
			t.Fatalf("validateInitialPacketSize(%d) error = %v", size, err)
		}
	}

	for _, size := range []int{1199, 1453} {
		if err := validateInitialPacketSize(size); err == nil {
			t.Fatalf("validateInitialPacketSize(%d) error = nil, want error", size)
		}
	}
}

func TestValidateDatagramSemantics(t *testing.T) {
	t.Parallel()

	for _, semantics := range []string{"", datagramSemanticsDrain, datagramSemanticsEcho} {
		if err := validateDatagramSemantics(semantics); err != nil {
			t.Fatalf("validateDatagramSemantics(%q) error = %v", semantics, err)
		}
	}

	if err := validateDatagramSemantics("mirror"); err == nil {
		t.Fatal("validateDatagramSemantics(mirror) error = nil, want error")
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
		}, ready, nil)
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
		}, ready, nil)
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

	statsOutput := filepath.Join(t.TempDir(), "server-stats.jsonl")
	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:              "127.0.0.1:0",
			certFile:          certs.serverCert,
			keyFile:           certs.serverKey,
			alpn:              "moqx-test",
			statsOutput:       statsOutput,
			datagramSemantics: datagramSemanticsEcho,
		}, ready, nil)
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

	serverStats := awaitServerRunEvidence(t, statsOutput)
	if serverStats.BidiStreamsAccepted != 1 {
		t.Fatalf("server bidi_streams_accepted = %d, want 1", serverStats.BidiStreamsAccepted)
	}
	if serverStats.UniStreamsAccepted != 2 {
		t.Fatalf("server uni_streams_accepted = %d, want 2", serverStats.UniStreamsAccepted)
	}
	if serverStats.StreamsCompleted != 3 {
		t.Fatalf("server streams_completed = %d, want 3", serverStats.StreamsCompleted)
	}
	if serverStats.StreamBytesReceived != expectedBytesSent {
		t.Fatalf("server stream_bytes_received = %d, want %d", serverStats.StreamBytesReceived, expectedBytesSent)
	}
	if serverStats.StreamBytesEchoAccepted != expectedControlBytes {
		t.Fatalf("server stream_bytes_echo_accepted = %d, want %d", serverStats.StreamBytesEchoAccepted, expectedControlBytes)
	}
	if serverStats.StreamReceiveErrorCount != 0 {
		t.Fatalf("server stream_receive_error_count = %d, want 0", serverStats.StreamReceiveErrorCount)
	}
	if serverStats.StreamSendErrorCount != 0 {
		t.Fatalf("server stream_send_error_count = %d, want 0", serverStats.StreamSendErrorCount)
	}
	if serverStats.DatagramsReceived != 0 {
		t.Fatalf("server datagrams_received = %d, want 0", serverStats.DatagramsReceived)
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

	statsOutput := filepath.Join(t.TempDir(), "server-stats.jsonl")
	ready := make(chan string, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- runServer(ctx, serverConfig{
			addr:              "127.0.0.1:0",
			certFile:          certs.serverCert,
			keyFile:           certs.serverKey,
			alpn:              "moqx-test",
			statsOutput:       statsOutput,
			datagramSemantics: datagramSemanticsEcho,
		}, ready, nil)
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
	serverStats := awaitServerRunEvidence(t, statsOutput)
	if serverStats.DatagramsReceived != 4 {
		t.Fatalf("server datagrams_received = %d, want 4", serverStats.DatagramsReceived)
	}
	if serverStats.DatagramsEchoAccepted != 4 {
		t.Fatalf("server datagrams_echo_accepted = %d, want 4", serverStats.DatagramsEchoAccepted)
	}
	if serverStats.DatagramBytesReceived != 4*64 {
		t.Fatalf("server datagram_bytes_received = %d, want %d", serverStats.DatagramBytesReceived, 4*64)
	}
	if serverStats.DatagramBytesEchoAccepted != 4*64 {
		t.Fatalf("server datagram_bytes_echo_accepted = %d, want %d", serverStats.DatagramBytesEchoAccepted, 4*64)
	}
	if serverStats.BidiStreamsAccepted != 0 {
		t.Fatalf("server bidi_streams_accepted = %d, want 0", serverStats.BidiStreamsAccepted)
	}
	if serverStats.UniStreamsAccepted != 0 {
		t.Fatalf("server uni_streams_accepted = %d, want 0", serverStats.UniStreamsAccepted)
	}
	if serverStats.StreamBytesReceived != 0 {
		t.Fatalf("server stream_bytes_received = %d, want 0", serverStats.StreamBytesReceived)
	}
	if serverStats.StreamBytesEchoAccepted != 0 {
		t.Fatalf("server stream_bytes_echo_accepted = %d, want 0", serverStats.StreamBytesEchoAccepted)
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

func TestEchoDatagramsDrainsReceivesWhileEchoSendIsBlocked(t *testing.T) {
	t.Parallel()

	payloads := make([][]byte, 256)
	for i := range payloads {
		payloads[i] = []byte{byte(i)}
	}

	conn := newBlockingEchoConn(payloads)
	resultc := make(chan datagramEchoStats, 1)
	go func() {
		resultc <- echoDatagrams(context.Background(), conn, nil)
	}()

	select {
	case <-conn.sendStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("SendDatagram was not called")
	}

	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadInt64(&conn.receivedCount) < int64(len(payloads)) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}

	if received := atomic.LoadInt64(&conn.receivedCount); received != int64(len(payloads)) {
		t.Fatalf("received count while send blocked = %d, want %d", received, len(payloads))
	}

	close(conn.unblockSend)

	select {
	case stats := <-resultc:
		if stats.datagramsReceived != len(payloads) {
			t.Fatalf("datagramsReceived = %d, want %d", stats.datagramsReceived, len(payloads))
		}
		if stats.datagramsEchoAccepted != len(payloads) {
			t.Fatalf("datagramsEchoAccepted = %d, want %d", stats.datagramsEchoAccepted, len(payloads))
		}
		if stats.echoQueueMaxDepth == 0 {
			t.Fatal("echoQueueMaxDepth = 0, want buffered echo backlog")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("echoDatagrams did not finish after unblocking sends")
	}
}

func TestDrainDatagramsDoesNotEcho(t *testing.T) {
	t.Parallel()

	payloads := [][]byte{
		[]byte("one"),
		[]byte("two"),
		[]byte("three"),
	}

	conn := newBlockingEchoConn(payloads)
	stats := drainDatagrams(context.Background(), conn, nil)

	if stats.datagramsReceived != len(payloads) {
		t.Fatalf("datagramsReceived = %d, want %d", stats.datagramsReceived, len(payloads))
	}
	if stats.bytesReceived != int64(len("one")+len("two")+len("three")) {
		t.Fatalf("bytesReceived = %d, want %d", stats.bytesReceived, len("one")+len("two")+len("three"))
	}
	if stats.datagramsEchoAccepted != 0 {
		t.Fatalf("datagramsEchoAccepted = %d, want 0", stats.datagramsEchoAccepted)
	}
	if stats.bytesEchoAccepted != 0 {
		t.Fatalf("bytesEchoAccepted = %d, want 0", stats.bytesEchoAccepted)
	}

	select {
	case <-conn.sendStarted:
		t.Fatal("SendDatagram was called in drain mode")
	default:
	}
}

func TestServerRunEvidenceRecorderWritesStdoutAndStatsOutput(t *testing.T) {
	t.Parallel()

	statsOutput := filepath.Join(t.TempDir(), "server-evidence.jsonl")
	var stdout bytes.Buffer
	recorder := newServerRunEvidenceRecorder(&stdout, statsOutput)

	startedAt := time.Unix(1_700_000_000, 123_000_000)
	finishedAt := startedAt.Add(1250 * time.Millisecond)
	snapshot := serverConnectionStatsSnapshot{
		startedAt:                 startedAt,
		finishedAt:                finishedAt,
		localAddr:                 "127.0.0.1:4433",
		remoteAddr:                "127.0.0.1:55555",
		alpn:                      "moqx-test",
		datagramSemantics:         datagramSemanticsEcho,
		datagramsReceived:         4,
		datagramsEchoAccepted:     3,
		datagramBytesReceived:     256,
		datagramBytesEchoAccepted: 192,
		echoQueueCapacity:         128,
		echoQueueMaxDepth:         2,
		bidiStreamsAccepted:       1,
		uniStreamsAccepted:        2,
		streamsCompleted:          3,
		streamBytesReceived:       512,
		streamBytesEchoed:         64,
		firstDatagramLatency:      10 * time.Millisecond,
		firstStreamByteLatency:    20 * time.Millisecond,
	}

	if err := recorder.Record(snapshot); err != nil {
		t.Fatalf("Record() error = %v", err)
	}

	stdoutEvidence := decodeServerRunEvidence(t, stdout.String())
	fileEvidence := awaitServerRunEvidence(t, statsOutput)

	assertServerRunEvidence(t, stdoutEvidence, 1)
	assertServerRunEvidence(t, fileEvidence, 1)

	if err := recorder.Record(snapshot); err != nil {
		t.Fatalf("second Record() error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("stdout evidence line count = %d, want 2\n%s", len(lines), stdout.String())
	}

	secondEvidence := decodeServerRunEvidence(t, lines[1])
	if secondEvidence.RunSequence != 2 {
		t.Fatalf("second run_sequence = %d, want 2", secondEvidence.RunSequence)
	}
}

func TestServerRunEvidenceHTTPAPI(t *testing.T) {
	t.Parallel()

	recorder := newServerRunEvidenceRecorder(nil, "")
	server := httptest.NewServer(recorder)
	defer server.Close()

	assertEvidenceLatestSequence(t, server.URL, 0)

	snapshot := serverConnectionStatsSnapshot{
		startedAt:              time.Unix(1_700_000_000, 0),
		finishedAt:             time.Unix(1_700_000_001, 0),
		localAddr:              "127.0.0.1:4433",
		remoteAddr:             "127.0.0.1:55555",
		alpn:                   "moqx-test",
		uniStreamsAccepted:     1,
		streamsCompleted:       1,
		streamBytesReceived:    512,
		firstStreamByteLatency: 3 * time.Millisecond,
	}

	if err := recorder.Record(snapshot); err != nil {
		t.Fatalf("Record() error = %v", err)
	}

	snapshot.streamBytesReceived = 1024
	if err := recorder.Record(snapshot); err != nil {
		t.Fatalf("Record() second error = %v", err)
	}

	assertEvidenceLatestSequence(t, server.URL, 2)

	var runs evidenceRunsResponse
	getJSON(t, server.URL+"/evidence/runs?after_sequence=1&limit=1", &runs)

	if runs.SchemaVersion != evidenceAPISchema {
		t.Fatalf("schema_version = %q, want %s", runs.SchemaVersion, evidenceAPISchema)
	}
	if runs.RecordType != "evidence_runs" {
		t.Fatalf("record_type = %q, want evidence_runs", runs.RecordType)
	}
	if runs.LatestRunSequence != 2 {
		t.Fatalf("latest_run_sequence = %d, want 2", runs.LatestRunSequence)
	}
	if len(runs.Runs) != 1 {
		t.Fatalf("runs length = %d, want 1", len(runs.Runs))
	}
	if runs.Runs[0].RunSequence != 2 {
		t.Fatalf("run_sequence = %d, want 2", runs.Runs[0].RunSequence)
	}
	if runs.Runs[0].StreamBytesReceived != 1024 {
		t.Fatalf("stream_bytes_received = %d, want 1024", runs.Runs[0].StreamBytesReceived)
	}
}

func TestExperimentLeaseHTTPAPI(t *testing.T) {
	t.Parallel()

	recorder := newServerRunEvidenceRecorder(nil, "")
	server := httptest.NewServer(recorder)
	defer server.Close()

	var initial experimentLeaseResponse
	getJSON(t, server.URL+"/experiment/lease", &initial)
	if initial.Status != "available" {
		t.Fatalf("initial lease status = %q, want available", initial.Status)
	}

	var acquired experimentLeaseResponse
	postJSON(t, server.URL+"/experiment/lease/acquire", http.StatusOK, experimentLeaseRequest{
		Owner: "suite-1",
		TTLMS: 60_000,
		Metadata: map[string]string{
			"profile": "draft14_object_datagram",
		},
	}, &acquired)

	if acquired.Status != "acquired" {
		t.Fatalf("acquire status = %q, want acquired", acquired.Status)
	}
	if acquired.Lease == nil {
		t.Fatal("acquire response lease is nil")
	}
	if acquired.Lease.Owner != "suite-1" {
		t.Fatalf("lease owner = %q, want suite-1", acquired.Lease.Owner)
	}
	if acquired.Lease.Token == "" {
		t.Fatal("lease token is empty")
	}

	var busy experimentLeaseResponse
	postJSON(t, server.URL+"/experiment/lease/acquire", http.StatusConflict, experimentLeaseRequest{
		Owner: "suite-2",
	}, &busy)
	if busy.Status != "busy" {
		t.Fatalf("busy status = %q, want busy", busy.Status)
	}
	if busy.Lease == nil || busy.Lease.Token != acquired.Lease.Token {
		t.Fatalf("busy lease token = %#v, want active lease token", busy.Lease)
	}

	snapshot := serverConnectionStatsSnapshot{
		startedAt:            time.Unix(1_700_000_000, 0),
		finishedAt:           time.Unix(1_700_000_001, 0),
		localAddr:            "127.0.0.1:4433",
		remoteAddr:           "127.0.0.1:55555",
		alpn:                 "moqx-test",
		experimentLeaseOwner: acquired.Lease.Owner,
		experimentLeaseToken: acquired.Lease.Token,
	}

	if err := recorder.Record(snapshot); err != nil {
		t.Fatalf("Record() error = %v", err)
	}

	var runs evidenceRunsResponse
	getJSON(t, server.URL+"/evidence/runs?after_sequence=0", &runs)
	if len(runs.Runs) != 1 {
		t.Fatalf("runs length = %d, want 1", len(runs.Runs))
	}
	if runs.Runs[0].ExperimentLeaseOwner != "suite-1" {
		t.Fatalf("evidence experiment lease owner = %q, want suite-1", runs.Runs[0].ExperimentLeaseOwner)
	}
	if runs.Runs[0].ExperimentLeaseToken != acquired.Lease.Token {
		t.Fatalf("evidence experiment lease token = %q, want %q", runs.Runs[0].ExperimentLeaseToken, acquired.Lease.Token)
	}

	var wrongRelease experimentLeaseResponse
	postJSON(t, server.URL+"/experiment/lease/release", http.StatusConflict, experimentLeaseRequest{
		Token: "wrong-token",
	}, &wrongRelease)
	if wrongRelease.Status != "not_released" {
		t.Fatalf("wrong release status = %q, want not_released", wrongRelease.Status)
	}

	var released experimentLeaseResponse
	postJSON(t, server.URL+"/experiment/lease/release", http.StatusOK, experimentLeaseRequest{
		Token: acquired.Lease.Token,
	}, &released)
	if released.Status != "released" {
		t.Fatalf("release status = %q, want released", released.Status)
	}

	var afterRelease experimentLeaseResponse
	getJSON(t, server.URL+"/experiment/lease", &afterRelease)
	if afterRelease.Status != "available" {
		t.Fatalf("after release status = %q, want available", afterRelease.Status)
	}
}

func TestServerRunEvidenceHTTPAPIRejectsInvalidQuery(t *testing.T) {
	t.Parallel()

	recorder := newServerRunEvidenceRecorder(nil, "")
	server := httptest.NewServer(recorder)
	defer server.Close()

	resp, err := http.Get(server.URL + "/evidence/runs?after_sequence=not-a-number")
	if err != nil {
		t.Fatalf("GET evidence runs error = %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

func TestServerRunEvidenceIgnoresNormalRemoteApplicationClose(t *testing.T) {
	t.Parallel()

	evidence := serverRunEvidenceFromSnapshot(1, serverConnectionStatsSnapshot{
		startedAt:          time.Unix(1_700_000_000, 0),
		finishedAt:         time.Unix(1_700_000_001, 0),
		alpn:               "moqx-test",
		datagramSemantics:  datagramSemanticsDrain,
		datagramReceiveErr: &quic.ApplicationError{Remote: true, ErrorCode: 0, ErrorMessage: "done"},
	})

	if !evidence.ReceiverEvidenceComplete {
		t.Fatalf("receiver_evidence_complete = false, cause=%q", evidence.ReceiverEvidenceFailureCause)
	}
	if evidence.DatagramReceiveError != "" {
		t.Fatalf("datagram_receive_error = %q, want empty", evidence.DatagramReceiveError)
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
			addr:              "127.0.0.1:0",
			certFile:          certs.serverCert,
			keyFile:           certs.serverKey,
			alpn:              "moqx-test",
			datagramSemantics: datagramSemanticsEcho,
		}, ready, nil)
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
	if result.SendDatagramCallSlowThresholdMS != 0.2 {
		t.Fatalf("send_datagram_call_slow_threshold_ms = %f, want 0.2", result.SendDatagramCallSlowThresholdMS)
	}
	if result.SendDatagramCallTotalMS <= 0 {
		t.Fatalf("send_datagram_call_total_ms = %f, want positive", result.SendDatagramCallTotalMS)
	}
	for _, key := range []string{"p99", "p999", "max"} {
		if _, ok := result.SendDatagramCallMS[key]; !ok {
			t.Fatalf("send datagram call summary = %#v, want %s", result.SendDatagramCallMS, key)
		}
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

func awaitServerRunEvidence(t *testing.T, path string) serverRunEvidence {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil && len(strings.TrimSpace(string(raw))) > 0 {
			return decodeServerRunEvidence(t, firstNonEmptyLine(string(raw)))
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("read server evidence: %v", err)
		}

		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("server evidence was not written to %s", path)
	return serverRunEvidence{}
}

func decodeServerRunEvidence(t *testing.T, raw string) serverRunEvidence {
	t.Helper()

	var evidence serverRunEvidence
	if err := json.Unmarshal([]byte(raw), &evidence); err != nil {
		t.Fatalf("server evidence JSON did not decode: %v\n%s", err, raw)
	}

	return evidence
}

func assertEvidenceLatestSequence(t *testing.T, baseURL string, want uint64) {
	t.Helper()

	var latest evidenceLatestResponse
	getJSON(t, baseURL+"/evidence/latest", &latest)

	if latest.SchemaVersion != evidenceAPISchema {
		t.Fatalf("schema_version = %q, want %s", latest.SchemaVersion, evidenceAPISchema)
	}
	if latest.RecordType != "evidence_latest" {
		t.Fatalf("record_type = %q, want evidence_latest", latest.RecordType)
	}
	if latest.LatestRunSequence != want {
		t.Fatalf("latest_run_sequence = %d, want %d", latest.LatestRunSequence, want)
	}
}

func getJSON(t *testing.T, url string, target any) {
	t.Helper()

	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s error = %v", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s status = %d, want %d", url, resp.StatusCode, http.StatusOK)
	}

	if err := json.NewDecoder(resp.Body).Decode(target); err != nil {
		t.Fatalf("GET %s JSON decode error = %v", url, err)
	}
}

func postJSON(t *testing.T, url string, wantStatus int, payload any, target any) {
	t.Helper()

	var body bytes.Buffer
	if err := json.NewEncoder(&body).Encode(payload); err != nil {
		t.Fatalf("POST %s JSON encode error = %v", url, err)
	}

	resp, err := http.Post(url, "application/json", &body)
	if err != nil {
		t.Fatalf("POST %s error = %v", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != wantStatus {
		t.Fatalf("POST %s status = %d, want %d", url, resp.StatusCode, wantStatus)
	}

	if err := json.NewDecoder(resp.Body).Decode(target); err != nil {
		t.Fatalf("POST %s JSON decode error = %v", url, err)
	}
}

func firstNonEmptyLine(raw string) string {
	for _, line := range strings.Split(raw, "\n") {
		if strings.TrimSpace(line) != "" {
			return line
		}
	}

	return ""
}

func assertServerRunEvidence(t *testing.T, evidence serverRunEvidence, sequence uint64) {
	t.Helper()

	if evidence.SchemaVersion != serverRunEvidenceSchema {
		t.Fatalf("schema_version = %q, want %s", evidence.SchemaVersion, serverRunEvidenceSchema)
	}
	if evidence.RecordType != serverRunEvidenceRecordType {
		t.Fatalf("record_type = %q, want %s", evidence.RecordType, serverRunEvidenceRecordType)
	}
	if evidence.RunSequence != sequence {
		t.Fatalf("run_sequence = %d, want %d", evidence.RunSequence, sequence)
	}
	if evidence.ALPN != "moqx-test" {
		t.Fatalf("alpn = %q, want moqx-test", evidence.ALPN)
	}
	if evidence.BidiStreamSemantics != "echo" {
		t.Fatalf("bidi_stream_semantics = %q, want echo", evidence.BidiStreamSemantics)
	}
	if evidence.UniStreamSemantics != "drain" {
		t.Fatalf("uni_stream_semantics = %q, want drain", evidence.UniStreamSemantics)
	}
	if evidence.DatagramSemantics != "echo" {
		t.Fatalf("datagram_semantics = %q, want echo", evidence.DatagramSemantics)
	}
	if !evidence.ReceiverEvidenceComplete {
		t.Fatalf("receiver_evidence_complete = false, cause=%q", evidence.ReceiverEvidenceFailureCause)
	}
	if evidence.DatagramsReceived != 4 {
		t.Fatalf("datagrams_received = %d, want 4", evidence.DatagramsReceived)
	}
	if evidence.DatagramsEchoAccepted != 3 {
		t.Fatalf("datagrams_echo_accepted = %d, want 3", evidence.DatagramsEchoAccepted)
	}
	if evidence.DatagramBytesReceived != 256 {
		t.Fatalf("datagram_bytes_received = %d, want 256", evidence.DatagramBytesReceived)
	}
	if evidence.DatagramBytesEchoAccepted != 192 {
		t.Fatalf("datagram_bytes_echo_accepted = %d, want 192", evidence.DatagramBytesEchoAccepted)
	}
	if evidence.BidiStreamsAccepted != 1 {
		t.Fatalf("bidi_streams_accepted = %d, want 1", evidence.BidiStreamsAccepted)
	}
	if evidence.UniStreamsAccepted != 2 {
		t.Fatalf("uni_streams_accepted = %d, want 2", evidence.UniStreamsAccepted)
	}
	if evidence.StreamsCompleted != 3 {
		t.Fatalf("streams_completed = %d, want 3", evidence.StreamsCompleted)
	}
	if evidence.StreamBytesReceived != 512 {
		t.Fatalf("stream_bytes_received = %d, want 512", evidence.StreamBytesReceived)
	}
	if evidence.StreamBytesEchoAccepted != 64 {
		t.Fatalf("stream_bytes_echo_accepted = %d, want 64", evidence.StreamBytesEchoAccepted)
	}
}

type blockingEchoConn struct {
	mu            sync.Mutex
	payloads      [][]byte
	receivedCount int64
	sendStarted   chan struct{}
	unblockSend   chan struct{}
}

func newBlockingEchoConn(payloads [][]byte) *blockingEchoConn {
	return &blockingEchoConn{
		payloads:    payloads,
		sendStarted: make(chan struct{}, 1),
		unblockSend: make(chan struct{}),
	}
}

func (c *blockingEchoConn) ReceiveDatagram(_ context.Context) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.payloads) == 0 {
		return nil, errors.New("receive complete")
	}

	payload := c.payloads[0]
	c.payloads = c.payloads[1:]
	atomic.AddInt64(&c.receivedCount, 1)
	return payload, nil
}

func (c *blockingEchoConn) SendDatagram(_ []byte) error {
	select {
	case c.sendStarted <- struct{}{}:
	default:
	}

	<-c.unblockSend
	return nil
}

func (c *blockingEchoConn) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 4433}
}

func (c *blockingEchoConn) RemoteAddr() net.Addr {
	return &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9443}
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

func TestParseServerConfigEvidenceBinMS(t *testing.T) {
	t.Parallel()

	base := []string{"-cert", "cert.pem", "-key", "key.pem"}

	cfg, err := parseServerConfig(base)
	if err != nil {
		t.Fatalf("parseServerConfig() error = %v", err)
	}
	if cfg.evidenceBinMS != defaultEvidenceBinMS {
		t.Fatalf("evidenceBinMS = %d, want %d", cfg.evidenceBinMS, defaultEvidenceBinMS)
	}

	cfg, err = parseServerConfig(append(base, "-evidence-bin-ms", "250"))
	if err != nil {
		t.Fatalf("parseServerConfig() with bin flag error = %v", err)
	}
	if cfg.evidenceBinMS != 250 {
		t.Fatalf("evidenceBinMS = %d, want 250", cfg.evidenceBinMS)
	}

	if _, err := parseServerConfig(append(base, "-evidence-bin-ms", "0")); err == nil {
		t.Fatal("parseServerConfig() with non-positive bin width: expected error")
	}
}

func TestIntervalBinAccumulatorBucketsByWindow(t *testing.T) {
	t.Parallel()

	acc := newIntervalBinAccumulator(100 * time.Millisecond)

	acc.addStream(10*time.Millisecond, 1200, 1)
	acc.addStream(50*time.Millisecond, 800, 1)
	acc.addStreamsCompleted(60*time.Millisecond, 1)
	acc.addDatagram(120*time.Millisecond, 512, 1)
	acc.addStream(370*time.Millisecond, 400, 1)

	bins := acc.snapshot()
	if len(bins) != 4 {
		t.Fatalf("bin count = %d, want 4 (gap-free windows through offset 370ms)", len(bins))
	}

	if bins[0].StartOffsetMS != 0 {
		t.Fatalf("bin[0] start_offset_ms = %v, want 0", bins[0].StartOffsetMS)
	}
	if bins[0].StreamBytes != 2000 {
		t.Fatalf("bin[0] stream_bytes = %d, want 2000", bins[0].StreamBytes)
	}
	if bins[0].StreamPayloadEvents != 2 {
		t.Fatalf("bin[0] stream_payload_events = %d, want 2", bins[0].StreamPayloadEvents)
	}
	if bins[0].StreamsCompleted != 1 {
		t.Fatalf("bin[0] streams_completed = %d, want 1", bins[0].StreamsCompleted)
	}

	if bins[1].StartOffsetMS != 100 {
		t.Fatalf("bin[1] start_offset_ms = %v, want 100", bins[1].StartOffsetMS)
	}
	if bins[1].Datagrams != 1 || bins[1].DatagramBytes != 512 {
		t.Fatalf("bin[1] datagrams = %d bytes = %d, want 1/512", bins[1].Datagrams, bins[1].DatagramBytes)
	}

	if bins[2].StreamBytes != 0 || bins[2].Datagrams != 0 {
		t.Fatalf("bin[2] should be an empty intermediate window, got %+v", bins[2])
	}

	if bins[3].StartOffsetMS != 300 || bins[3].StreamBytes != 400 {
		t.Fatalf("bin[3] = %+v, want start 300 / stream_bytes 400", bins[3])
	}
}
