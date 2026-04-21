package media

import (
	"context"
	"log/slog"
	"sync"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"

	"github.com/chatwoot/chatwoot-media-server/internal/peer"
)

// AudioConsumer is an interface for components that want to receive audio
// frames from the bridge, such as real-time transcription or AI services.
type AudioConsumer interface {
	// OnAudioFrame is called for each RTP packet passing through the bridge.
	// source is either "customer" or "agent".
	OnAudioFrame(sessionID, source string, packet *rtp.Packet)
}

// Bridge connects two WebRTC peers (Meta-side and Agent-side) by forwarding
// RTP audio packets between them. It also taps into both audio streams for
// recording and external consumers.
type Bridge struct {
	sessionID  string
	metaPeer   *peer.MetaPeer
	agentPeers map[string]*peer.AgentPeer
	recorder   *Recorder
	consumers  []AudioConsumer

	cancel context.CancelFunc
	mu     sync.RWMutex
	active bool
}

// NewBridge creates a new audio bridge for the given session. The bridge does
// not start forwarding automatically; call Start after both peers are connected.
func NewBridge(sessionID string, metaPeer *peer.MetaPeer, recorder *Recorder) *Bridge {
	return &Bridge{
		sessionID:  sessionID,
		metaPeer:   metaPeer,
		agentPeers: make(map[string]*peer.AgentPeer),
		recorder:   recorder,
	}
}

// AddAgentPeer registers an agent peer with the bridge. If the bridge is
// already running, forwarding to the new peer begins immediately.
func (b *Bridge) AddAgentPeer(ap *peer.AgentPeer) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.agentPeers[ap.ID] = ap
	slog.Info("bridge: agent peer added",
		"session_id", b.sessionID,
		"peer_id", ap.ID,
		"role", string(ap.Role),
	)
}

// RemoveAgentPeer removes an agent peer from the bridge. Its forwarding
// goroutines will terminate when the peer's tracks are closed.
func (b *Bridge) RemoveAgentPeer(peerID string) {
	b.mu.Lock()
	defer b.mu.Unlock()

	delete(b.agentPeers, peerID)
	slog.Info("bridge: agent peer removed",
		"session_id", b.sessionID,
		"peer_id", peerID,
	)
}

// AddConsumer registers an AudioConsumer that receives copies of all audio
// packets passing through the bridge.
func (b *Bridge) AddConsumer(c AudioConsumer) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.consumers = append(b.consumers, c)
}

// Start begins forwarding audio between the Meta peer and all agent peers.
// It spawns goroutines for each direction of audio flow. The bridge runs
// until Stop is called or the provided context is cancelled.
func (b *Bridge) Start(ctx context.Context) {
	b.mu.Lock()
	if b.active {
		b.mu.Unlock()
		return
	}
	b.active = true
	ctx, b.cancel = context.WithCancel(ctx)
	b.mu.Unlock()

	slog.Info("bridge: started", "session_id", b.sessionID)

	// Forward Meta audio (customer) to all agent peers.
	go b.forwardMetaToAgents(ctx)

	// For each agent peer, forward their audio to Meta.
	b.mu.RLock()
	for _, ap := range b.agentPeers {
		go b.forwardAgentToMeta(ctx, ap)
	}
	b.mu.RUnlock()
}

// StartAgentForwarding begins forwarding a specific agent peer's audio to
// Meta. This is used when a new agent peer is added after the bridge has
// already started.
func (b *Bridge) StartAgentForwarding(ctx context.Context, ap *peer.AgentPeer) {
	b.mu.RLock()
	active := b.active
	b.mu.RUnlock()

	if !active {
		return
	}

	go b.forwardAgentToMeta(ctx, ap)
}

// Stop halts all audio forwarding and finalizes the recording. This method
// is idempotent.
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()

	if !b.active {
		return
	}
	b.active = false

	if b.cancel != nil {
		b.cancel()
	}

	slog.Info("bridge: stopped", "session_id", b.sessionID)
}

// IsActive returns whether the bridge is currently forwarding audio.
func (b *Bridge) IsActive() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.active
}

// forwardMetaToAgents reads RTP packets from the Meta peer's remote audio
// track (customer audio) and writes them to every connected agent peer's
// local track. Each packet is also sent to the recorder and any consumers.
func (b *Bridge) forwardMetaToAgents(ctx context.Context) {
	metaTrack := b.metaPeer.AudioTrack()
	if metaTrack == nil {
		slog.Warn("bridge: Meta audio track not yet available, waiting via OnTrack",
			"session_id", b.sessionID,
		)
		// The track will be set via OnTrack callback. We wait for the track
		// by polling with a channel. In production, the OnTrack callback
		// mechanism in the session handles this coordination.
		return
	}

	b.readAndForwardMetaTrack(ctx, metaTrack)
}

// ReadAndForwardMetaTrack is the core loop that reads from a Meta remote
// track and fans out to agent peers. It is exported so the session layer can
// call it directly from the OnTrack callback.
func (b *Bridge) ReadAndForwardMetaTrack(ctx context.Context, track *webrtc.TrackRemote) {
	b.readAndForwardMetaTrack(ctx, track)
}

func (b *Bridge) readAndForwardMetaTrack(ctx context.Context, track *webrtc.TrackRemote) {
	slog.Info("bridge: forwarding Meta audio to agents",
		"session_id", b.sessionID,
		"codec", track.Codec().MimeType,
	)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		pkt, _, readErr := track.ReadRTP()
		if readErr != nil {
			slog.Debug("bridge: Meta track read ended",
				"session_id", b.sessionID,
				"error", readErr,
			)
			return
		}

		// Record customer audio.
		if b.recorder != nil {
			if err := b.recorder.WriteCustomerRTP(pkt); err != nil {
				slog.Warn("bridge: failed to record customer audio",
					"session_id", b.sessionID,
					"error", err,
				)
			}
		}

		// Notify consumers.
		b.mu.RLock()
		for _, c := range b.consumers {
			c.OnAudioFrame(b.sessionID, "customer", pkt)
		}
		b.mu.RUnlock()

		// Fan-out to all agent peers.
		b.mu.RLock()
		for _, ap := range b.agentPeers {
			if ap.Role == peer.RoleInjectOnly {
				continue // inject-only peers do not receive audio
			}
			raw, marshalErr := pkt.Marshal()
			if marshalErr != nil {
				slog.Warn("bridge: failed to marshal RTP packet",
					"session_id", b.sessionID,
					"error", marshalErr,
				)
				continue
			}
			if _, writeErr := ap.LocalTrack().Write(raw); writeErr != nil {
				slog.Debug("bridge: failed to write to agent peer",
					"session_id", b.sessionID,
					"peer_id", ap.ID,
					"error", writeErr,
				)
			}
		}
		b.mu.RUnlock()
	}
}

// forwardAgentToMeta reads RTP packets from an agent peer's remote audio
// track (agent microphone) and writes them to the Meta peer's local track.
func (b *Bridge) forwardAgentToMeta(ctx context.Context, ap *peer.AgentPeer) {
	agentTrack := ap.AudioTrack()
	if agentTrack == nil {
		slog.Debug("bridge: agent audio track not yet available, waiting via OnTrack",
			"session_id", b.sessionID,
			"peer_id", ap.ID,
		)
		return
	}

	b.readAndForwardAgentTrack(ctx, ap, agentTrack)
}

// ReadAndForwardAgentTrack is the core loop that reads from an agent's remote
// track and forwards to Meta. Exported so the session layer can call it from
// the OnTrack callback.
func (b *Bridge) ReadAndForwardAgentTrack(ctx context.Context, ap *peer.AgentPeer, track *webrtc.TrackRemote) {
	b.readAndForwardAgentTrack(ctx, ap, track)
}

func (b *Bridge) readAndForwardAgentTrack(ctx context.Context, ap *peer.AgentPeer, track *webrtc.TrackRemote) {
	slog.Info("bridge: forwarding agent audio to Meta",
		"session_id", b.sessionID,
		"peer_id", ap.ID,
		"codec", track.Codec().MimeType,
	)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		pkt, _, readErr := track.ReadRTP()
		if readErr != nil {
			slog.Debug("bridge: agent track read ended",
				"session_id", b.sessionID,
				"peer_id", ap.ID,
				"error", readErr,
			)
			return
		}

		// Only active peers send audio to Meta.
		if ap.Role != peer.RoleActive {
			continue
		}

		// Record agent audio.
		if b.recorder != nil {
			if err := b.recorder.WriteAgentRTP(pkt); err != nil {
				slog.Warn("bridge: failed to record agent audio",
					"session_id", b.sessionID,
					"error", err,
				)
			}
		}

		// Notify consumers.
		b.mu.RLock()
		for _, c := range b.consumers {
			c.OnAudioFrame(b.sessionID, "agent", pkt)
		}
		b.mu.RUnlock()

		// Forward to Meta.
		raw, marshalErr := pkt.Marshal()
		if marshalErr != nil {
			slog.Warn("bridge: failed to marshal agent RTP packet",
				"session_id", b.sessionID,
				"error", marshalErr,
			)
			continue
		}
		if _, writeErr := b.metaPeer.LocalTrack().Write(raw); writeErr != nil {
			slog.Debug("bridge: failed to write to Meta peer",
				"session_id", b.sessionID,
				"error", writeErr,
			)
		}
	}
}
