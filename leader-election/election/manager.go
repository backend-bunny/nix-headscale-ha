// Package election implements a priority-based leader election with majority
// quorum to prevent split-brain in clusters of 3+ nodes.
//
// # Algorithm
//
// Each node periodically probes all configured peers via HTTP GET /status.
//
// Quorum requirement: a node may only become (or remain) leader when a strict
// majority of the cluster is reachable from it:
//
//	quorum = floor(totalNodes/2) + 1
//
// where totalNodes = len(peers) + 1 (self).  This mirrors Raft's safety rule
// without requiring a replicated log:
//
//   - 3-node cluster: quorum = 2 — a partition of 1 cannot elect a leader.
//   - 4-node cluster: quorum = 3 — only the larger side of any partition elects.
//   - 5-node cluster: quorum = 3 — tolerates 2 simultaneous failures.
//
// Among all healthy nodes that satisfy quorum, the winner is the one with the
// lowest NodePriority value (tie-break: lexicographic NodeID).  Because every
// node applies the same deterministic rule over the same set of observations,
// all nodes in the quorate partition converge on the same leader without any
// extra coordination round-trips.
//
// # Split-brain safety
//
// In a 3-node cluster: if a network partition produces a 1-vs-2 split, the
// single isolated node observes only 1 healthy node (< quorum 2) and steps
// down.  The 2-node side observes 2 healthy nodes (≥ quorum 2) and elects the
// highest-priority member.  No two nodes can simultaneously believe they are
// leader.
//
// For even cluster sizes (2, 4, …) a symmetric 50/50 split leaves both halves
// below quorum and the cluster stalls until connectivity is restored.  This is
// the correct safe behaviour: stalling is better than split-brain.  Prefer odd
// cluster sizes (3, 5) for maximum availability.
package election

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/nix-headscale-ha/leader-election/config"
)

// PeerStatus is the JSON payload returned by every node's GET /status endpoint.
type PeerStatus struct {
	NodeID       string    `json:"nodeId"`
	NodePriority int       `json:"nodePriority"`
	IsLeader     bool      `json:"isLeader"`
	HasQuorum    bool      `json:"hasQuorum"`
	LeaderID     string    `json:"leaderId"`
	TotalNodes   int       `json:"totalNodes"`
	HealthyNodes int       `json:"healthyNodes"`
	Quorum       int       `json:"quorum"`
	Peers        []string  `json:"peers"`
	Timestamp    time.Time `json:"timestamp"`
}

// peerHealth tracks the most recent successful probe of a remote peer.
type peerHealth struct {
	url          string
	status       *PeerStatus
	lastSeenAt   time.Time
	reachable    bool
}

// Manager runs the election loop and exposes the current leadership view.
type Manager struct {
	cfg        *config.Config
	totalNodes int // len(peers) + 1 (self); fixed at startup
	quorum     int // floor(totalNodes/2) + 1; fixed at startup

	mu           sync.RWMutex
	peerMap      map[string]*peerHealth // keyed by peer URL
	isLeader     bool
	hasQuorum    bool
	healthyNodes int
	leaderID     string

	httpClient *http.Client
}

// New creates a Manager but does not start the background goroutine yet.
//
// tlsCfg is the client-side *tls.Config used when probing peers over mTLS.
// Pass nil to probe peers over plain HTTP (dev / no-TLS mode).
func New(cfg *config.Config, tlsCfg *tls.Config) *Manager {
	total := len(cfg.Peers) + 1 // +1 for self

	// Build an HTTP client that uses the supplied TLS config when non-nil.
	// The Transport is created explicitly so we can inject RootCAs and the
	// client certificate without touching the shared http.DefaultTransport.
	var transport http.RoundTripper
	if tlsCfg != nil {
		transport = &http.Transport{
			TLSClientConfig: tlsCfg,
		}
	}

	m := &Manager{
		cfg:        cfg,
		totalNodes: total,
		quorum:     total/2 + 1,
		peerMap:    make(map[string]*peerHealth, len(cfg.Peers)),
		httpClient: &http.Client{
			Timeout:   cfg.HTTPTimeout,
			Transport: transport, // nil = use http.DefaultTransport (plain HTTP)
		},
	}
	for _, p := range cfg.Peers {
		m.peerMap[p] = &peerHealth{url: p}
	}
	slog.Info("election manager initialised",
		"totalNodes", m.totalNodes,
		"quorum", m.quorum,
	)
	return m
}

// Run starts the background heartbeat loop.  It blocks until ctx is cancelled.
func (m *Manager) Run(ctx context.Context) {
	ticker := time.NewTicker(m.cfg.HeartbeatInterval)
	defer ticker.Stop()

	// Probe immediately on start so we don't wait a full interval.
	m.probe()
	m.elect()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.probe()
			m.elect()
		}
	}
}

// Status returns a snapshot of this node's current view of the cluster.
func (m *Manager) Status() PeerStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()

	reachable := make([]string, 0, len(m.peerMap))
	for _, ph := range m.peerMap {
		if ph.reachable {
			reachable = append(reachable, ph.url)
		}
	}

	return PeerStatus{
		NodeID:       m.cfg.NodeID,
		NodePriority: m.cfg.NodePriority,
		IsLeader:     m.isLeader,
		HasQuorum:    m.hasQuorum,
		LeaderID:     m.leaderID,
		TotalNodes:   m.totalNodes,
		HealthyNodes: m.healthyNodes,
		Quorum:       m.quorum,
		Peers:        reachable,
		Timestamp:    time.Now(),
	}
}

// IsLeader returns true if this node is currently the elected leader.
func (m *Manager) IsLeader() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.isLeader
}

// -----------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------

// probe concurrently GETs /status from every peer and updates peerMap.
func (m *Manager) probe() {
	var wg sync.WaitGroup
	results := make(chan struct {
		url    string
		status *PeerStatus
		err    error
	}, len(m.cfg.Peers))

	for _, url := range m.cfg.Peers {
		wg.Add(1)
		go func(u string) {
			defer wg.Done()
			ps, err := m.fetchStatus(u)
			results <- struct {
				url    string
				status *PeerStatus
				err    error
			}{u, ps, err}
		}(url)
	}
	wg.Wait()
	close(results)

	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()

	for r := range results {
		ph := m.peerMap[r.url]
		if r.err != nil {
			slog.Debug("peer probe failed", "peer", r.url, "err", r.err)
			// Mark dead only after DeadThreshold has elapsed since last success.
			if now.Sub(ph.lastSeenAt) > m.cfg.DeadThreshold {
				ph.reachable = false
			}
		} else {
			ph.status = r.status
			ph.lastSeenAt = now
			ph.reachable = true
		}
	}
}

// elect re-evaluates leadership based on the current peerMap snapshot.
// Must be called after probe() has updated the map.
//
// Quorum rule: at least (totalNodes/2 + 1) nodes must be healthy before any
// node is allowed to become, or remain, the leader.  A node that cannot reach
// quorum steps down immediately and sets leaderID to "" so callers can surface
// the degraded state.
func (m *Manager) elect() {
	m.mu.Lock()
	defer m.mu.Unlock()

	// ── 1. count healthy nodes ──────────────────────────────────────────────
	// Self is always counted as healthy (we are running).
	healthy := 1
	for _, ph := range m.peerMap {
		if ph.reachable {
			healthy++
		}
	}
	m.healthyNodes = healthy
	m.hasQuorum = healthy >= m.quorum

	// ── 2. quorum gate ──────────────────────────────────────────────────────
	if !m.hasQuorum {
		if m.isLeader {
			slog.Warn("quorum lost — stepping down",
				"nodeId", m.cfg.NodeID,
				"healthy", healthy,
				"quorum", m.quorum,
				"total", m.totalNodes,
			)
		}
		m.isLeader = false
		m.leaderID = ""
		return
	}

	// ── 3. elect among the healthy set ─────────────────────────────────────
	// Winner = lowest NodePriority value; tie-break: lexicographic NodeID.
	bestPriority := m.cfg.NodePriority
	bestID := m.cfg.NodeID

	for _, ph := range m.peerMap {
		if !ph.reachable || ph.status == nil {
			continue
		}
		p := ph.status.NodePriority
		id := ph.status.NodeID
		if p < bestPriority || (p == bestPriority && id < bestID) {
			bestPriority = p
			bestID = id
		}
	}

	prevLeader := m.isLeader
	m.leaderID = bestID
	m.isLeader = (bestID == m.cfg.NodeID)

	if m.isLeader != prevLeader {
		if m.isLeader {
			slog.Info("leadership acquired",
				"nodeId", m.cfg.NodeID,
				"healthy", healthy,
				"quorum", m.quorum,
			)
		} else {
			slog.Info("leadership released",
				"nodeId", m.cfg.NodeID,
				"newLeader", m.leaderID,
			)
		}
	}
}

// fetchStatus calls GET <url>/status and unmarshals the response.
func (m *Manager) fetchStatus(baseURL string) (*PeerStatus, error) {
	resp, err := m.httpClient.Get(fmt.Sprintf("%s/status", baseURL))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %d from %s", resp.StatusCode, baseURL)
	}

	var ps PeerStatus
	if err := json.NewDecoder(resp.Body).Decode(&ps); err != nil {
		return nil, fmt.Errorf("decode error from %s: %w", baseURL, err)
	}
	return &ps, nil
}
