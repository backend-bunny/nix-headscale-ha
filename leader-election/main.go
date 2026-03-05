// headscale-leader-election — lightweight leader election daemon for headscale HA.
//
// Each node in the cluster runs this process.  The election algorithm is a
// priority-based distributed probe: every node periodically polls all peers
// and independently decides who the leader is by choosing the healthy node
// with the lowest priority number.  No external coordination service is
// required.
//
// # Listeners
//
// The daemon exposes two HTTP listeners:
//
//  1. Plain HTTP on --listen-addr (default :50555) — used by the local watchdog
//     and by Caddy active health checks from other nodes.  No TLS required
//     because the information served (/status, /leader, /healthz) is non-sensitive
//     and Caddy does not support client certificates on upstream health checks.
//
//  2. mTLS on --tls-listen-addr (default :50556) — used only for peer-to-peer
//     gossip probes.  Activated when --tls-ca-file, --tls-cert-file, and
//     --tls-key-file are all provided.  Both the server and client present a
//     certificate signed by the shared cluster CA; connections from holders of
//     any other certificate are rejected before any data is exchanged.
//
// # Usage
//
//	headscale-leader-election \
//	  --node-id=node1 \
//	  --node-priority=10 \
//	  --listen-addr=:50555 \
//	  --tls-listen-addr=:50556 \
//	  --peers=https://192.168.1.12:50556,https://192.168.1.13:50556 \
//	  --tls-ca-file=/run/secrets/le-ca.crt \
//	  --tls-cert-file=/run/secrets/le-node1.crt \
//	  --tls-key-file=/run/secrets/le-node1.key
//
// # Environment variables
//
//	NODE_ID, NODE_PRIORITY, LISTEN_ADDR, TLS_LISTEN_ADDR, PEERS,
//	TLS_CA_FILE, TLS_CERT_FILE, TLS_KEY_FILE
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nix-headscale-ha/leader-election/api"
	"github.com/nix-headscale-ha/leader-election/config"
	"github.com/nix-headscale-ha/leader-election/election"
)

func main() {
	// Structured JSON logging — plays nicely with journald / systemd.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	cfg, err := config.Load()
	if err != nil {
		slog.Error("config load failed", "err", err)
		os.Exit(1)
	}

	// Build TLS configs (returns nil, nil when TLS files are not configured).
	serverTLSCfg, clientTLSCfg, err := buildTLSConfigs(cfg.TLSCAFile, cfg.TLSCertFile, cfg.TLSKeyFile)
	if err != nil {
		slog.Error("TLS config failed", "err", err)
		os.Exit(1)
	}

	tlsEnabled := serverTLSCfg != nil
	slog.Info("starting leader-election",
		"nodeId", cfg.NodeID,
		"nodePriority", cfg.NodePriority,
		"listenAddr", cfg.ListenAddr,
		"tlsListenAddr", cfg.TLSListenAddr,
		"tlsEnabled", tlsEnabled,
		"peers", cfg.Peers,
	)

	mgr := election.New(cfg, clientTLSCfg)

	// Root context — cancelled on SIGTERM / SIGINT.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	// Start the election loop in a background goroutine.
	go mgr.Run(ctx)

	handler := api.Handler(mgr)

	newServer := func(addr string) *http.Server {
		return &http.Server{
			Addr:         addr,
			Handler:      handler,
			ReadTimeout:  5 * time.Second,
			WriteTimeout: 5 * time.Second,
			IdleTimeout:  60 * time.Second,
		}
	}

	errCh := make(chan error, 2)

	// ── Listener 1: plain HTTP (watchdog + Caddy health checks) ──────────
	plainSrv := newServer(cfg.ListenAddr)
	go func() {
		slog.Info("plain HTTP server listening", "addr", cfg.ListenAddr)
		if err := plainSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- fmt.Errorf("plain HTTP: %w", err)
		}
	}()

	// ── Listener 2: mTLS (peer gossip) — only when certs are provided ────
	var tlsSrv *http.Server
	if tlsEnabled {
		tlsSrv = newServer("") // Addr unused; we pass a tls.Listener to Serve
		go func() {
			ln, err := net.Listen("tcp", cfg.TLSListenAddr)
			if err != nil {
				errCh <- fmt.Errorf("mTLS listen: %w", err)
				return
			}
			tlsLn := tls.NewListener(ln, serverTLSCfg)
			slog.Info("mTLS peer server listening", "addr", cfg.TLSListenAddr)
			if err := tlsSrv.Serve(tlsLn); err != nil && err != http.ErrServerClosed {
				errCh <- fmt.Errorf("mTLS server: %w", err)
			}
		}()
	}

	// Block until signal or server error.
	select {
	case <-ctx.Done():
		slog.Info("shutdown signal received")
	case err := <-errCh:
		slog.Error("server error", "err", err)
		os.Exit(1)
	}

	// Graceful shutdown.
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutCancel()
	if err := plainSrv.Shutdown(shutCtx); err != nil {
		slog.Error("plain HTTP shutdown error", "err", err)
	}
	if tlsSrv != nil {
		if err := tlsSrv.Shutdown(shutCtx); err != nil {
			slog.Error("mTLS server shutdown error", "err", err)
		}
	}

	slog.Info("shutdown complete")
}

// buildTLSConfigs constructs a server and client *tls.Config from the cluster
// PKI files.  Returns (nil, nil, nil) when all paths are empty (dev mode).
//
// The server config requires client certificates signed by the cluster CA
// (RequireAndVerifyClientCert).  The client config presents the node's own
// certificate and verifies the server's certificate against the same CA.
// Both sides enforce TLS 1.3 as the minimum version.
func buildTLSConfigs(caFile, certFile, keyFile string) (serverCfg, clientCfg *tls.Config, err error) {
	if caFile == "" && certFile == "" && keyFile == "" {
		return nil, nil, nil // plaintext / dev mode
	}

	// Load cluster CA.
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, nil, fmt.Errorf("read CA file %q: %w", caFile, err)
	}
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caPEM) {
		return nil, nil, fmt.Errorf("failed to parse any certificate from CA file %q", caFile)
	}

	// Load this node's certificate + private key.
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, nil, fmt.Errorf("load node cert/key (%q / %q): %w", certFile, keyFile, err)
	}

	// Server config: require and verify the client's certificate against the
	// cluster CA — this is what gates peer gossip auth.
	serverCfg = &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    caPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}

	// Client config: present our certificate and verify the server's cert
	// against the same cluster CA.
	clientCfg = &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caPool,
		MinVersion:   tls.VersionTLS13,
	}

	return serverCfg, clientCfg, nil
}

