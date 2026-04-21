// Package media provides audio bridging, recording, and injection capabilities
// for the media server's call sessions.
package media

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4/pkg/media/oggwriter"
)

// Recorder writes incoming Opus RTP packets to an OGG container file in real
// time. Two separate OGG files are maintained -- one for each audio channel
// (customer and agent) -- to enable stereo separation for transcription.
// A combined mono file is also written for playback convenience.
type Recorder struct {
	sessionID string
	dir       string

	// combinedWriter writes all audio to a single OGG file (for playback).
	combinedWriter *oggwriter.OggWriter
	combinedFile   string

	// customerWriter writes only customer audio (for transcription L channel).
	customerWriter *oggwriter.OggWriter
	customerFile   string

	// agentWriter writes only agent audio (for transcription R channel).
	agentWriter *oggwriter.OggWriter
	agentFile   string

	startedAt time.Time
	finalized bool
	mu        sync.Mutex
}

// NewRecorder creates a new recorder that writes OGG/Opus files to the given
// directory. Three files are created:
//   - {sessionID}.ogg (combined audio for playback)
//   - {sessionID}_customer.ogg (customer channel only)
//   - {sessionID}_agent.ogg (agent channel only)
func NewRecorder(sessionID, dir string) (*Recorder, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create recordings directory: %w", err)
	}

	combinedFile := filepath.Join(dir, sessionID+".ogg")
	customerFile := filepath.Join(dir, sessionID+"_customer.ogg")
	agentFile := filepath.Join(dir, sessionID+"_agent.ogg")

	// Opus at 48kHz, mono for each individual channel.
	combinedWriter, err := oggwriter.New(combinedFile, 48000, 1)
	if err != nil {
		return nil, fmt.Errorf("create combined OGG writer: %w", err)
	}

	customerWriter, err := oggwriter.New(customerFile, 48000, 1)
	if err != nil {
		combinedWriter.Close()
		return nil, fmt.Errorf("create customer OGG writer: %w", err)
	}

	agentWriter, err := oggwriter.New(agentFile, 48000, 1)
	if err != nil {
		combinedWriter.Close()
		customerWriter.Close()
		return nil, fmt.Errorf("create agent OGG writer: %w", err)
	}

	slog.Info("recorder: started",
		"session_id", sessionID,
		"combined_file", combinedFile,
	)

	return &Recorder{
		sessionID:      sessionID,
		dir:            dir,
		combinedWriter: combinedWriter,
		combinedFile:   combinedFile,
		customerWriter: customerWriter,
		customerFile:   customerFile,
		agentWriter:    agentWriter,
		agentFile:      agentFile,
		startedAt:      time.Now(),
	}, nil
}

// WriteCustomerRTP writes an RTP packet from the customer's audio stream
// (Meta-side, Peer A) to the recording. The packet is written to both the
// combined file and the customer-only channel file.
func (r *Recorder) WriteCustomerRTP(pkt *rtp.Packet) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.finalized {
		return nil
	}

	if err := r.combinedWriter.WriteRTP(pkt); err != nil {
		return fmt.Errorf("write customer RTP to combined: %w", err)
	}
	if err := r.customerWriter.WriteRTP(pkt); err != nil {
		return fmt.Errorf("write customer RTP to channel: %w", err)
	}
	return nil
}

// WriteAgentRTP writes an RTP packet from the agent's audio stream
// (browser-side, Peer B) to the recording.
func (r *Recorder) WriteAgentRTP(pkt *rtp.Packet) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.finalized {
		return nil
	}

	if err := r.combinedWriter.WriteRTP(pkt); err != nil {
		return fmt.Errorf("write agent RTP to combined: %w", err)
	}
	if err := r.agentWriter.WriteRTP(pkt); err != nil {
		return fmt.Errorf("write agent RTP to channel: %w", err)
	}
	return nil
}

// Finalize closes all OGG writers and flushes data to disk. After finalization,
// further writes are silently ignored. This method is idempotent.
func (r *Recorder) Finalize() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.finalized {
		return nil
	}
	r.finalized = true

	var errs []error
	if err := r.combinedWriter.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close combined writer: %w", err))
	}
	if err := r.customerWriter.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close customer writer: %w", err))
	}
	if err := r.agentWriter.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close agent writer: %w", err))
	}

	if len(errs) > 0 {
		return fmt.Errorf("finalize recorder: %v", errs)
	}

	slog.Info("recorder: finalized",
		"session_id", r.sessionID,
		"duration", time.Since(r.startedAt).Round(time.Second),
	)
	return nil
}

// CombinedFilePath returns the filesystem path of the combined recording file.
func (r *Recorder) CombinedFilePath() string {
	return r.combinedFile
}

// CustomerFilePath returns the filesystem path of the customer-only recording.
func (r *Recorder) CustomerFilePath() string {
	return r.customerFile
}

// AgentFilePath returns the filesystem path of the agent-only recording.
func (r *Recorder) AgentFilePath() string {
	return r.agentFile
}

// Duration returns the elapsed recording time since the recorder was started.
func (r *Recorder) Duration() time.Duration {
	return time.Since(r.startedAt)
}

// FileSize returns the size of the combined recording file in bytes, or -1 on
// error.
func (r *Recorder) FileSize() int64 {
	info, err := os.Stat(r.combinedFile)
	if err != nil {
		return -1
	}
	return info.Size()
}

// Cleanup removes all recording files for this session from disk.
func (r *Recorder) Cleanup() {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, f := range []string{r.combinedFile, r.customerFile, r.agentFile} {
		if err := os.Remove(f); err != nil && !os.IsNotExist(err) {
			slog.Warn("recorder: failed to remove file",
				"file", f,
				"error", err,
			)
		}
	}
}
