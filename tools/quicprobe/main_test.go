package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
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
