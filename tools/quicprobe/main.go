package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"time"

	quic "github.com/quic-go/quic-go"
)

const defaultALPN = "moqx-test"

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
	}, &quic.Config{})
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
	for {
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			return
		}

		go handleBidiEchoStream(stream)
	}
}

func handleBidiEchoStream(stream quic.Stream) {
	buffer := make([]byte, 64*1024)
	n, err := stream.Read(buffer)
	if err != nil && err != io.EOF {
		stream.CancelWrite(1)
		return
	}

	if _, err := stream.Write(buffer[:n]); err != nil {
		stream.CancelWrite(1)
		return
	}

	_ = stream.Close()
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

	conn, err := quic.DialAddr(ctx, cfg.addr, &tls.Config{
		MinVersion: tls.VersionTLS13,
		RootCAs:    roots,
		ServerName: serverName,
		NextProtos: []string{cfg.alpn},
	}, &quic.Config{})
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.CloseWithError(0, "done")

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

	echo, err := io.ReadAll(stream)
	if err != nil {
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

func envOrDefault(key string, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}

	return fallback
}
