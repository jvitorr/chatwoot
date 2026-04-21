// Package callback provides an HTTP client for sending event notifications
// back to the Chatwoot Rails application.
package callback

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

// RailsClient sends HTTP callbacks to the Rails application to notify it of
// media server events such as agent disconnection, recording availability,
// session termination, and errors.
type RailsClient struct {
	baseURL   string
	authToken string
	client    *http.Client
}

// NewRailsClient creates a new callback client configured with the Rails base
// URL and shared authentication token. The HTTP client uses a 10-second
// timeout to avoid blocking the media server on slow Rails responses.
func NewRailsClient(baseURL, authToken string) *RailsClient {
	return &RailsClient{
		baseURL:   baseURL,
		authToken: authToken,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// AgentDisconnectedPayload is the request body sent when an agent's peer
// connection drops unexpectedly.
type AgentDisconnectedPayload struct {
	SessionID string `json:"session_id"`
	CallID    string `json:"call_id"`
	Reason    string `json:"reason"`
}

// RecordingReadyPayload is the request body sent when a call recording has
// been finalized and is available for download.
type RecordingReadyPayload struct {
	SessionID      string `json:"session_id"`
	CallID         string `json:"call_id"`
	FilePath       string `json:"file_path"`
	DurationSec    int    `json:"duration_seconds"`
	FileSizeBytes  int64  `json:"file_size_bytes"`
}

// SessionTerminatedPayload is the request body sent when a call session has
// been fully terminated and cleaned up.
type SessionTerminatedPayload struct {
	SessionID   string `json:"session_id"`
	CallID      string `json:"call_id"`
	Reason      string `json:"reason"`
	DurationSec int    `json:"duration_seconds"`
}

// ErrorPayload is the request body sent when the media server encounters
// an error that the Rails application should be aware of.
type ErrorPayload struct {
	SessionID string `json:"session_id"`
	CallID    string `json:"call_id"`
	Error     string `json:"error"`
	Code      string `json:"code"`
}

// NotifyAgentDisconnected informs Rails that an agent's WebRTC peer connection
// has dropped. Rails can then start the reconnection timer and update the call
// status accordingly.
func (c *RailsClient) NotifyAgentDisconnected(ctx context.Context, payload AgentDisconnectedPayload) error {
	return c.post(ctx, "/callbacks/media_server/agent_disconnected", payload)
}

// NotifyRecordingReady informs Rails that a call recording has been finalized
// and is available for download via the GET /sessions/:id/recording endpoint.
// Rails should enqueue a job to fetch and attach the recording to ActiveStorage.
func (c *RailsClient) NotifyRecordingReady(ctx context.Context, payload RecordingReadyPayload) error {
	return c.post(ctx, "/callbacks/media_server/recording_ready", payload)
}

// NotifySessionTerminated informs Rails that a call session has ended. This
// is sent after both peer connections are closed and the recording is finalized.
func (c *RailsClient) NotifySessionTerminated(ctx context.Context, payload SessionTerminatedPayload) error {
	return c.post(ctx, "/callbacks/media_server/session_terminated", payload)
}

// NotifyError informs Rails of a media server error that may require attention,
// such as a failed ICE negotiation or recording write failure.
func (c *RailsClient) NotifyError(ctx context.Context, payload ErrorPayload) error {
	return c.post(ctx, "/callbacks/media_server/error", payload)
}

func (c *RailsClient) post(ctx context.Context, path string, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal callback payload: %w", err)
	}

	url := c.baseURL + path
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create callback request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		slog.Error("callback request failed",
			"url", url,
			"error", err,
		)
		return fmt.Errorf("callback request to %s: %w", path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		slog.Error("callback returned error status",
			"url", url,
			"status", resp.StatusCode,
		)
		return fmt.Errorf("callback to %s returned status %d", path, resp.StatusCode)
	}

	slog.Debug("callback sent successfully",
		"url", url,
		"status", resp.StatusCode,
	)
	return nil
}
