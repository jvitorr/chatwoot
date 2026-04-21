package session

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/chatwoot/chatwoot-media-server/internal/callback"
	"github.com/chatwoot/chatwoot-media-server/internal/config"
	"github.com/chatwoot/chatwoot-media-server/internal/peer"
)

// Manager handles the lifecycle of all call sessions, providing thread-safe
// creation, lookup, termination, and periodic cleanup of expired sessions.
type Manager struct {
	sessions    map[string]*Session
	config      *config.Config
	railsClient *callback.RailsClient

	mu              sync.RWMutex
	sessionCounter  atomic.Int64
	cleanupTicker   *time.Ticker
	cleanupStopCh   chan struct{}
}

// Metrics holds observable counters for the session manager, used by the
// /metrics endpoint.
type Metrics struct {
	ActiveSessions    int   `json:"active_sessions"`
	TotalCreated      int64 `json:"total_created"`
	TerminatedCount   int   `json:"terminated_count"`
	MetaConnected     int   `json:"meta_connected"`
	AgentConnected    int   `json:"agent_connected"`
	AgentDisconnected int   `json:"agent_disconnected"`
}

// NewManager creates a new session manager and starts a background goroutine
// that periodically cleans up expired sessions.
func NewManager(cfg *config.Config, railsClient *callback.RailsClient) *Manager {
	m := &Manager{
		sessions:      make(map[string]*Session),
		config:        cfg,
		railsClient:   railsClient,
		cleanupTicker: time.NewTicker(60 * time.Second),
		cleanupStopCh: make(chan struct{}),
	}

	go m.cleanupLoop()
	return m
}

// CreateSession creates a new call session with the given parameters. For
// incoming calls, metaSDPOffer contains Meta's SDP offer and the returned
// string is the SDP answer. For outgoing calls, metaSDPOffer is empty and
// the returned string is the SDP offer to send to Meta.
func (m *Manager) CreateSession(callID, accountID, direction, metaSDPOffer string, iceServers []webrtc.ICEServer) (*Session, string, error) {
	// Check capacity limit.
	if m.config.MaxConcurrentSessions > 0 {
		m.mu.RLock()
		activeCount := len(m.sessions)
		m.mu.RUnlock()

		if activeCount >= m.config.MaxConcurrentSessions {
			return nil, "", fmt.Errorf("max concurrent sessions (%d) reached", m.config.MaxConcurrentSessions)
		}
	}

	// Generate a unique session ID.
	counter := m.sessionCounter.Add(1)
	sessionID := fmt.Sprintf("sess_%s_%d", time.Now().Format("20060102150405"), counter)

	sess, sdpResult, err := NewSession(m.config, m.railsClient, sessionID, callID, accountID, direction, metaSDPOffer, iceServers)
	if err != nil {
		return nil, "", fmt.Errorf("create session: %w", err)
	}

	m.mu.Lock()
	m.sessions[sessionID] = sess
	m.mu.Unlock()

	slog.Info("manager: session created",
		"session_id", sessionID,
		"call_id", callID,
		"direction", direction,
	)

	return sess, sdpResult, nil
}

// GetSession returns the session with the given ID, or nil if not found.
func (m *Manager) GetSession(sessionID string) *Session {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.sessions[sessionID]
}

// TerminateSession terminates the session with the given ID and removes it
// from the active sessions map.
func (m *Manager) TerminateSession(sessionID, reason string) error {
	m.mu.Lock()
	sess, ok := m.sessions[sessionID]
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("session %s not found", sessionID)
	}
	delete(m.sessions, sessionID)
	m.mu.Unlock()

	sess.Terminate(reason)
	return nil
}

// DeleteSession removes a session and cleans up its recording files.
func (m *Manager) DeleteSession(sessionID string) error {
	m.mu.Lock()
	sess, ok := m.sessions[sessionID]
	if ok {
		delete(m.sessions, sessionID)
	}
	m.mu.Unlock()

	if !ok {
		return fmt.Errorf("session %s not found", sessionID)
	}

	sess.Terminate("deleted")

	// Clean up recording files.
	if sess.Recorder != nil {
		sess.Recorder.Cleanup()
	}

	return nil
}

// CreateAgentPeer creates a new agent-side peer for the specified session.
func (m *Manager) CreateAgentPeer(sessionID, peerID string, role peer.PeerRole, iceServers []webrtc.ICEServer) (string, error) {
	sess := m.GetSession(sessionID)
	if sess == nil {
		return "", fmt.Errorf("session %s not found", sessionID)
	}
	return sess.CreateAgentPeer(peerID, role, iceServers)
}

// SetAgentAnswer sets the agent's SDP answer for the specified peer.
func (m *Manager) SetAgentAnswer(sessionID, peerID, sdpAnswer string) error {
	sess := m.GetSession(sessionID)
	if sess == nil {
		return fmt.Errorf("session %s not found", sessionID)
	}
	return sess.SetAgentAnswer(peerID, sdpAnswer)
}

// ReconnectAgent creates a new agent peer after tearing down the old one.
func (m *Manager) ReconnectAgent(sessionID, oldPeerID, newPeerID string, role peer.PeerRole, iceServers []webrtc.ICEServer) (string, error) {
	sess := m.GetSession(sessionID)
	if sess == nil {
		return "", fmt.Errorf("session %s not found", sessionID)
	}
	return sess.ReconnectAgent(oldPeerID, newPeerID, role, iceServers)
}

// GetMetrics returns current observable metrics about the session manager.
func (m *Manager) GetMetrics() Metrics {
	m.mu.RLock()
	defer m.mu.RUnlock()

	metrics := Metrics{
		ActiveSessions: len(m.sessions),
		TotalCreated:   m.sessionCounter.Load(),
	}

	for _, sess := range m.sessions {
		switch sess.Status {
		case StatusTerminated:
			metrics.TerminatedCount++
		case StatusMetaConnected:
			metrics.MetaConnected++
		case StatusAgentConnected, StatusActive:
			metrics.AgentConnected++
		case StatusAgentDisconnected:
			metrics.AgentDisconnected++
		}
	}

	return metrics
}

// RecoverOrphanedRecordings scans the recordings directory for files that
// do not belong to any active session, reporting them to Rails. This handles
// the case where the media server crashed mid-call and recordings were left
// on disk.
func (m *Manager) RecoverOrphanedRecordings() {
	dir := m.config.RecordingsDir
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return
		}
		slog.Error("manager: failed to scan recordings directory",
			"dir", dir,
			"error", err,
		)
		return
	}

	m.mu.RLock()
	activeIDs := make(map[string]bool, len(m.sessions))
	for id := range m.sessions {
		activeIDs[id] = true
	}
	m.mu.RUnlock()

	orphanCount := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".ogg") {
			continue
		}

		// Extract session ID from filename (e.g., "sess_20240101_1.ogg" -> "sess_20240101_1").
		name := strings.TrimSuffix(entry.Name(), ".ogg")
		// Remove channel suffixes.
		name = strings.TrimSuffix(name, "_customer")
		name = strings.TrimSuffix(name, "_agent")

		if !activeIDs[name] {
			orphanCount++
			slog.Warn("manager: found orphaned recording",
				"file", filepath.Join(dir, entry.Name()),
				"session_id", name,
			)
		}
	}

	if orphanCount > 0 {
		slog.Info("manager: orphaned recording scan complete",
			"orphan_count", orphanCount,
		)
	}
}

// Shutdown gracefully terminates all active sessions and stops the cleanup
// goroutine. It should be called during server shutdown.
func (m *Manager) Shutdown() {
	close(m.cleanupStopCh)
	m.cleanupTicker.Stop()

	m.mu.Lock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, sess := range m.sessions {
		sessions = append(sessions, sess)
	}
	m.sessions = make(map[string]*Session)
	m.mu.Unlock()

	for _, sess := range sessions {
		sess.Terminate("server_shutdown")
	}

	slog.Info("manager: all sessions terminated", "count", len(sessions))
}

// cleanupLoop runs periodically to remove terminated sessions from the map.
func (m *Manager) cleanupLoop() {
	for {
		select {
		case <-m.cleanupStopCh:
			return
		case <-m.cleanupTicker.C:
			m.cleanup()
		}
	}
}

func (m *Manager) cleanup() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for id, sess := range m.sessions {
		if sess.Status == StatusTerminated {
			delete(m.sessions, id)
			slog.Debug("manager: cleaned up terminated session", "session_id", id)
		}
	}
}
