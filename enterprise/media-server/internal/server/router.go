// Package server provides the HTTP API router and handlers for the media server.
package server

import (
	"log/slog"
	"net/http"
	"strings"

	"github.com/chatwoot/chatwoot-media-server/internal/auth"
	"github.com/chatwoot/chatwoot-media-server/internal/config"
	"github.com/chatwoot/chatwoot-media-server/internal/session"
)

// Router builds the HTTP handler tree with authentication middleware and
// route matching. It uses the standard library's http.ServeMux for routing.
type Router struct {
	handler  *Handlers
	authToken string
}

// NewRouter creates a new Router with the given configuration, session
// manager, and authentication token.
func NewRouter(cfg *config.Config, mgr *session.Manager) *Router {
	return &Router{
		handler:  NewHandlers(cfg, mgr),
		authToken: cfg.AuthToken,
	}
}

// Build constructs and returns the root http.Handler with all routes and
// middleware applied.
func (rt *Router) Build() http.Handler {
	mux := http.NewServeMux()

	// Public endpoints (no auth required).
	mux.HandleFunc("GET /health", rt.handler.Health)

	// Protected endpoints.
	authMw := auth.Middleware(rt.authToken)

	// Session CRUD.
	mux.Handle("POST /sessions", authMw(http.HandlerFunc(rt.handler.CreateSession)))
	mux.Handle("GET /metrics", authMw(http.HandlerFunc(rt.handler.Metrics)))

	// All session-scoped routes go through a path-parsing handler because
	// Go 1.22's ServeMux supports {param} patterns.
	mux.Handle("GET /sessions/{id}", authMw(http.HandlerFunc(rt.handler.GetSession)))
	mux.Handle("POST /sessions/{id}/agent-offer", authMw(http.HandlerFunc(rt.handler.AgentOffer)))
	mux.Handle("POST /sessions/{id}/agent-answer", authMw(http.HandlerFunc(rt.handler.AgentAnswer)))
	mux.Handle("POST /sessions/{id}/meta-answer", authMw(http.HandlerFunc(rt.handler.MetaAnswer)))
	mux.Handle("POST /sessions/{id}/agent-reconnect", authMw(http.HandlerFunc(rt.handler.AgentReconnect)))
	mux.Handle("POST /sessions/{id}/terminate", authMw(http.HandlerFunc(rt.handler.TerminateSession)))
	mux.Handle("GET /sessions/{id}/recording", authMw(http.HandlerFunc(rt.handler.GetRecording)))
	mux.Handle("DELETE /sessions/{id}", authMw(http.HandlerFunc(rt.handler.DeleteSession)))

	// Multi-participant peer management.
	mux.Handle("POST /sessions/{id}/peers", authMw(http.HandlerFunc(rt.handler.AddPeer)))
	mux.Handle("DELETE /sessions/{id}/peers/{peer_id}", authMw(http.HandlerFunc(rt.handler.RemovePeer)))
	mux.Handle("PATCH /sessions/{id}/peers/{peer_id}/role", authMw(http.HandlerFunc(rt.handler.ChangePeerRole)))

	// Audio injection.
	mux.Handle("POST /sessions/{id}/inject-audio", authMw(http.HandlerFunc(rt.handler.InjectAudio)))
	mux.Handle("DELETE /sessions/{id}/inject-audio/{inj_id}", authMw(http.HandlerFunc(rt.handler.StopInjectAudio)))

	// Wrap the mux with global middleware.
	var handler http.Handler = mux
	handler = requestLogger(handler)
	handler = recoverer(handler)

	return handler
}

// requestLogger is middleware that logs each HTTP request.
func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip logging for health checks to reduce noise.
		if strings.HasPrefix(r.URL.Path, "/health") {
			next.ServeHTTP(w, r)
			return
		}

		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(rw, r)

		// Logging is handled inside handlers for better context; this is
		// a safety net for unlogged requests.
	})
}

// recoverer is middleware that catches panics and returns a 500 response
// instead of crashing the server.
func recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				slog.Error("panic recovered",
					"panic", rec,
					"path", r.URL.Path,
					"method", r.Method,
				)
				http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// responseWriter wraps http.ResponseWriter to capture the status code.
type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
