// Package config loads and validates the service configuration from environment
// variables and command-line flags.
package config

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

// Config holds all runtime configuration for a leader-election node.
type Config struct {
	// NodeID is the stable, unique identifier for this node (e.g. "node1").
	NodeID string

	// NodePriority determines which node becomes leader when multiple candidates
	// are healthy. Lower number == higher priority. The node with the lowest
	// priority value that is reachable wins the election.
	NodePriority int

	// ListenAddr is the address:port on which this node's plain HTTP API
	// listens.  This endpoint is used by the local watchdog and Caddy active
	// health checks — it does NOT require client certificates.
	ListenAddr string

	// TLSListenAddr is the address:port for the mTLS peer-gossip listener.
	// Only active when all three TLS* file paths are non-empty.
	// Peers must point their probe URLs at this address.
	TLSListenAddr string

	// Peers is the list of advertise URLs of all other nodes in the cluster.
	// When mTLS is enabled these must be https:// URLs pointing at each peer's
	// TLSListenAddr (e.g. "https://192.168.1.12:50556").
	// This node's own address must NOT be included.
	Peers []string

	// HeartbeatInterval is how often the node probes its peers.
	HeartbeatInterval time.Duration

	// DeadThreshold is how long without a successful probe before a peer is
	// considered dead and excluded from the election.
	DeadThreshold time.Duration

	// HTTPTimeout is the per-request timeout used when probing peers.
	HTTPTimeout time.Duration

	// TLS fields — leave all three empty to run without mTLS (dev/test mode).
	// When any one is set all three must be set.
	TLSCAFile   string // path to cluster CA certificate (PEM)
	TLSCertFile string // path to this node's certificate (PEM), signed by CA
	TLSKeyFile  string // path to this node's private key (PEM)
}

// Load parses flags and environment variables and returns a validated Config.
func Load() (*Config, error) {
	c := &Config{}

	flag.StringVar(&c.NodeID, "node-id", env("NODE_ID", ""), "Unique node identifier (required)")
	flag.IntVar(&c.NodePriority, "node-priority", envInt("NODE_PRIORITY", 100), "Election priority – lower wins (default 100)")
	flag.StringVar(&c.ListenAddr, "listen-addr", env("LISTEN_ADDR", ":50555"), "Plain HTTP listen address (watchdog + Caddy health checks)")
	flag.StringVar(&c.TLSListenAddr, "tls-listen-addr", env("TLS_LISTEN_ADDR", ":50556"), "mTLS listen address for peer gossip (active only when TLS certs are configured)")

	peersRaw := flag.String("peers", env("PEERS", ""), "Comma-separated list of peer advertise URLs")

	flag.DurationVar(&c.HeartbeatInterval, "heartbeat-interval", 2*time.Second, "Peer probe interval")
	flag.DurationVar(&c.DeadThreshold, "dead-threshold", 8*time.Second, "Time without response before peer is dead")
	flag.DurationVar(&c.HTTPTimeout, "http-timeout", 2*time.Second, "HTTP request timeout for peer probes")

	flag.StringVar(&c.TLSCAFile, "tls-ca-file", env("TLS_CA_FILE", ""), "Cluster CA certificate (PEM) — enables mTLS peer auth")
	flag.StringVar(&c.TLSCertFile, "tls-cert-file", env("TLS_CERT_FILE", ""), "This node's TLS certificate (PEM), signed by the cluster CA")
	flag.StringVar(&c.TLSKeyFile, "tls-key-file", env("TLS_KEY_FILE", ""), "This node's TLS private key (PEM)")

	flag.Parse()

	if c.NodeID == "" {
		return nil, fmt.Errorf("--node-id / NODE_ID is required")
	}
	if *peersRaw != "" {
		for _, p := range strings.Split(*peersRaw, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				c.Peers = append(c.Peers, p)
			}
		}
	}

	// TLS fields must all be set or all empty.
	tlsCount := 0
	for _, f := range []string{c.TLSCAFile, c.TLSCertFile, c.TLSKeyFile} {
		if f != "" {
			tlsCount++
		}
	}
	if tlsCount > 0 && tlsCount < 3 {
		return nil, fmt.Errorf("mTLS requires all three of --tls-ca-file, --tls-cert-file, --tls-key-file (got %d/3)", tlsCount)
	}

	return c, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}


func envInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	var n int
	if _, err := fmt.Sscanf(v, "%d", &n); err != nil {
		return def
	}
	return n
}
