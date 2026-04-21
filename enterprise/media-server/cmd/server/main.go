// Package main is the entry point for the chatwoot-media-server binary. It
// loads configuration, initializes the session manager, sets up HTTP routes,
// and starts the server with graceful shutdown support.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/chatwoot/chatwoot-media-server/internal/callback"
	"github.com/chatwoot/chatwoot-media-server/internal/config"
	"github.com/chatwoot/chatwoot-media-server/internal/server"
	"github.com/chatwoot/chatwoot-media-server/internal/session"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal error", "error", err)
		os.Exit(1)
	}
}

func run() error {
	// Load configuration from environment variables.
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	// Configure structured logging.
	setupLogging(cfg.LogLevel)

	// Log configuration warnings.
	for _, w := range cfg.Validate() {
		slog.Warn("config warning", "message", w)
	}

	slog.Info("starting chatwoot-media-server",
		"http_port", cfg.HTTPPort,
		"udp_port_range", fmt.Sprintf("%d-%d", cfg.UDPPortMin, cfg.UDPPortMax),
		"recordings_dir", cfg.RecordingsDir,
	)

	// Ensure recordings directory exists.
	if err := os.MkdirAll(cfg.RecordingsDir, 0o755); err != nil {
		return fmt.Errorf("create recordings directory: %w", err)
	}

	// Initialize the Rails callback client.
	railsClient := callback.NewRailsClient(cfg.RailsCallbackURL, cfg.AuthToken)

	// Initialize the session manager.
	mgr := session.NewManager(cfg, railsClient)

	// Recover any orphaned recordings from a previous crash.
	mgr.RecoverOrphanedRecordings()

	// Build the HTTP router.
	router := server.NewRouter(cfg, mgr)
	handler := router.Build()

	// Create the HTTP server.
	srv := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:      handler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start the server in a goroutine.
	errCh := make(chan error, 1)
	go func() {
		slog.Info("HTTP server listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- fmt.Errorf("HTTP server error: %w", err)
		}
	}()

	// Wait for shutdown signal or server error.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		slog.Info("received shutdown signal", "signal", sig.String())
	case err := <-errCh:
		return err
	}

	// Graceful shutdown: stop accepting new connections, drain existing ones.
	slog.Info("initiating graceful shutdown")

	// First, terminate all active sessions so recordings are finalized.
	mgr.Shutdown()

	// Then shut down the HTTP server with a timeout.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("HTTP server shutdown error: %w", err)
	}

	slog.Info("server stopped gracefully")
	return nil
}

// setupLogging configures the global slog logger with the given level.
func setupLogging(level string) {
	var logLevel slog.Level
	switch level {
	case "debug":
		logLevel = slog.LevelDebug
	case "warn":
		logLevel = slog.LevelWarn
	case "error":
		logLevel = slog.LevelError
	default:
		logLevel = slog.LevelInfo
	}

	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: logLevel,
	})
	slog.SetDefault(slog.New(handler))
}
