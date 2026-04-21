// Package auth provides HTTP authentication middleware for the media server API.
package auth

import (
	"crypto/subtle"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
)

// Middleware returns an HTTP middleware that validates Bearer token authentication.
// Requests without a valid token receive a 401 Unauthorized response. If the
// configured token is empty, all requests are allowed (development mode).
func Middleware(token string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Skip auth if no token is configured (development mode).
			if token == "" {
				next.ServeHTTP(w, r)
				return
			}

			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				slog.Warn("missing Authorization header",
					"path", r.URL.Path,
					"remote_addr", r.RemoteAddr,
				)
				writeAuthError(w, "missing Authorization header")
				return
			}

			// Extract Bearer token.
			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
				slog.Warn("invalid Authorization header format",
					"path", r.URL.Path,
					"remote_addr", r.RemoteAddr,
				)
				writeAuthError(w, "invalid Authorization header format")
				return
			}

			// Constant-time comparison to prevent timing attacks.
			if subtle.ConstantTimeCompare([]byte(parts[1]), []byte(token)) != 1 {
				slog.Warn("invalid auth token",
					"path", r.URL.Path,
					"remote_addr", r.RemoteAddr,
				)
				writeAuthError(w, "invalid auth token")
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// writeAuthError writes a JSON-formatted 401 error response.
func writeAuthError(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	fmt.Fprintf(w, `{"error":%q}`, msg)
}
