package media

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4/pkg/media/oggreader"
)

// Injector reads Opus frames from an OGG file and injects them into an RTP
// stream at the correct 20ms pacing interval. This is used for hold music,
// announcements, and other pre-recorded audio injection.
type Injector struct {
	ID     string
	Source string // file path of the OGG/Opus file
	Mode   string // "replace" or "mix"
	Loop   bool
	Target string // "meta", "agents", or "all"

	stopCh chan struct{}
	mu     sync.Mutex
	active bool
}

// InjectorTarget is a writable RTP destination.
type InjectorTarget interface {
	Write(b []byte) (n int, err error)
}

// NewInjector creates a new audio injector configured with the given source
// file and injection parameters.
func NewInjector(id, source, mode, target string, loop bool) *Injector {
	return &Injector{
		ID:     id,
		Source: source,
		Mode:   mode,
		Loop:   loop,
		Target: target,
		stopCh: make(chan struct{}),
	}
}

// Start begins reading the OGG file and injecting Opus frames into the target
// track at 20ms intervals. It runs in its own goroutine and returns immediately.
// The injection stops when Stop is called, the file ends (if Loop is false),
// or an error occurs.
func (inj *Injector) Start(target InjectorTarget) error {
	inj.mu.Lock()
	if inj.active {
		inj.mu.Unlock()
		return fmt.Errorf("injector %s is already active", inj.ID)
	}
	inj.active = true
	inj.stopCh = make(chan struct{}) // fresh channel for each start cycle
	inj.mu.Unlock()

	go inj.run(target)
	return nil
}

// Stop halts the audio injection. This method is safe to call multiple times.
func (inj *Injector) Stop() {
	inj.mu.Lock()
	defer inj.mu.Unlock()

	if !inj.active {
		return
	}
	inj.active = false
	close(inj.stopCh)

	slog.Info("injector: stopped", "id", inj.ID)
}

// IsActive returns whether the injector is currently running.
func (inj *Injector) IsActive() bool {
	inj.mu.Lock()
	defer inj.mu.Unlock()
	return inj.active
}

func (inj *Injector) run(target InjectorTarget) {
	defer func() {
		inj.mu.Lock()
		inj.active = false
		inj.mu.Unlock()
	}()

	slog.Info("injector: started",
		"id", inj.ID,
		"source", inj.Source,
		"mode", inj.Mode,
		"loop", inj.Loop,
	)

	for {
		if err := inj.playFile(target); err != nil {
			slog.Error("injector: playback error",
				"id", inj.ID,
				"error", err,
			)
			return
		}

		if !inj.Loop {
			slog.Info("injector: playback complete (no loop)", "id", inj.ID)
			return
		}

		// Check stop signal between loops.
		select {
		case <-inj.stopCh:
			return
		default:
		}
	}
}

func (inj *Injector) playFile(target InjectorTarget) error {
	f, err := os.Open(inj.Source)
	if err != nil {
		return fmt.Errorf("open source file: %w", err)
	}
	defer f.Close()

	ogg, _, err := oggreader.NewWith(f)
	if err != nil {
		return fmt.Errorf("create OGG reader: %w", err)
	}

	// Opus frames are 20ms at 48kHz = 960 samples per frame.
	const opusFrameDuration = 20 * time.Millisecond
	ticker := time.NewTicker(opusFrameDuration)
	defer ticker.Stop()

	var sequenceNumber uint16
	var timestamp uint32

	for {
		select {
		case <-inj.stopCh:
			return nil
		case <-ticker.C:
		}

		pageData, _, err := ogg.ParseNextPage()
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return fmt.Errorf("parse OGG page: %w", err)
		}

		// Build an RTP packet with the Opus payload.
		pkt := &rtp.Packet{
			Header: rtp.Header{
				Version:        2,
				PayloadType:    111, // Opus dynamic payload type
				SequenceNumber: sequenceNumber,
				Timestamp:      timestamp,
				SSRC:           12345678, // fixed SSRC for injected audio
			},
			Payload: pageData,
		}
		sequenceNumber++
		timestamp += 960 // 48kHz * 0.02s

		raw, marshalErr := pkt.Marshal()
		if marshalErr != nil {
			slog.Warn("injector: failed to marshal RTP packet",
				"id", inj.ID,
				"error", marshalErr,
			)
			continue
		}

		if _, writeErr := target.Write(raw); writeErr != nil {
			slog.Debug("injector: write failed",
				"id", inj.ID,
				"error", writeErr,
			)
		}
	}
}
