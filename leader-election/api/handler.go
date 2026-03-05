// Package api wires up the HTTP endpoints exposed by a leader-election node.
//
// Endpoints
//
//	GET /status   — Full cluster view (JSON). Used by peer probes and the watchdog.
//	GET /healthz  — Returns 200 OK always (node process is alive).
//	GET /leader   — Returns 200 if this node is leader, 503 otherwise.
//	              Used by Caddy's active health checks to route traffic only to
//	              the node that is currently running headscale.
package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/nix-headscale-ha/leader-election/election"
)

// Handler returns an http.Handler that serves all leader-election API routes.
func Handler(mgr *election.Manager) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /status", statusHandler(mgr))
	mux.HandleFunc("GET /healthz", healthzHandler())
	mux.HandleFunc("GET /leader", leaderHandler(mgr))

	// Middleware: request logging.
	return logMiddleware(mux)
}

// -----------------------------------------------------------------------
// Route handlers
// -----------------------------------------------------------------------

func statusHandler(mgr *election.Manager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(mgr.Status()); err != nil {
			slog.Error("status encode error", "err", err)
		}
	}
}

func healthzHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	}
}

// leaderHandler returns 200 when this node is the current leader.
// Caddy (and any external load balancer) can use this as a health-check path
// so that only the active headscale node receives traffic.
//
// The response body always includes "hasQuorum" so operators can distinguish
// "not leader but cluster is healthy" from "no quorum — cluster is degraded".
func leaderHandler(mgr *election.Manager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		st := mgr.Status()
		if st.IsLeader {
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"isLeader":     true,
				"nodeId":       st.NodeID,
				"hasQuorum":    st.HasQuorum,
				"healthyNodes": st.HealthyNodes,
				"quorum":       st.Quorum,
				"totalNodes":   st.TotalNodes,
			})
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"isLeader":     false,
				"nodeId":       st.NodeID,
				"leaderId":     st.LeaderID,
				"hasQuorum":    st.HasQuorum,
				"healthyNodes": st.HealthyNodes,
				"quorum":       st.Quorum,
				"totalNodes":   st.TotalNodes,
			})
		}
	}
}

// -----------------------------------------------------------------------
// Middleware
// -----------------------------------------------------------------------

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(rw, r)
		slog.Debug("http",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rw.statusCode,
			"duration", time.Since(start),
			"remote", r.RemoteAddr,
		)
	})
}
