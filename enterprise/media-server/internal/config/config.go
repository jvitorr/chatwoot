// Package config provides environment-based configuration for the media server.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds all configuration values for the media server, loaded from
// environment variables at startup. Sensible defaults are provided for
// development; production deployments should set AUTH_TOKEN and RAILS_CALLBACK_URL
// at a minimum.
type Config struct {
	// AuthToken is the shared secret used for Bearer token authentication
	// between Rails and the media server. Required in production.
	AuthToken string

	// RailsCallbackURL is the base URL for HTTP callbacks to the Rails app
	// (e.g., "http://rails:3000").
	RailsCallbackURL string

	// STUNServers is a list of STUN server URLs for ICE candidate gathering.
	STUNServers []string

	// TURNServers is a list of TURN server URLs for relay candidates.
	TURNServers []string

	// TURNUsername is the credential username for TURN servers.
	TURNUsername string

	// TURNPassword is the credential password for TURN servers.
	TURNPassword string

	// PublicIP is the server's public IP address used for ICE candidate
	// generation via NAT1To1IPs. Leave empty to rely on STUN discovery.
	PublicIP string

	// UDPPortMin is the lower bound of the ephemeral UDP port range used
	// for WebRTC media transport.
	UDPPortMin uint16

	// UDPPortMax is the upper bound of the ephemeral UDP port range.
	UDPPortMax uint16

	// RecordingsDir is the filesystem path where call recordings are stored.
	RecordingsDir string

	// HTTPPort is the port on which the HTTP API listens.
	HTTPPort int

	// LogLevel controls the verbosity of structured logging.
	// Valid values: "debug", "info", "warn", "error".
	LogLevel string

	// MaxSessionDuration is the maximum allowed duration for a single call
	// session before automatic termination.
	MaxSessionDuration time.Duration

	// ReconnectTimeout is the duration the server waits for an agent to
	// reconnect after their peer connection drops before terminating the call.
	ReconnectTimeout time.Duration

	// MaxConcurrentSessions limits the total number of active sessions across
	// all accounts. Zero means unlimited.
	MaxConcurrentSessions int
}

// Load reads configuration from environment variables and returns a validated
// Config. It returns an error if any required value is missing or invalid.
func Load() (*Config, error) {
	cfg := &Config{
		AuthToken:        getEnv("AUTH_TOKEN", ""),
		RailsCallbackURL: getEnv("RAILS_CALLBACK_URL", "http://localhost:3000"),
		TURNUsername:     getEnv("TURN_USERNAME", ""),
		TURNPassword:     getEnv("TURN_PASSWORD", ""),
		PublicIP:         getEnv("PUBLIC_IP", ""),
		RecordingsDir:    getEnv("RECORDINGS_DIR", "/recordings"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
	}

	// Parse STUN servers (comma-separated).
	stunStr := getEnv("STUN_SERVERS", "stun:stun.l.google.com:19302")
	if stunStr != "" {
		cfg.STUNServers = splitAndTrim(stunStr)
	}

	// Parse TURN servers (comma-separated).
	turnStr := getEnv("TURN_SERVERS", "")
	if turnStr != "" {
		cfg.TURNServers = splitAndTrim(turnStr)
	}

	// Parse UDP port range.
	portMin, err := getEnvUint16("UDP_PORT_MIN", 10000)
	if err != nil {
		return nil, fmt.Errorf("invalid UDP_PORT_MIN: %w", err)
	}
	cfg.UDPPortMin = portMin

	portMax, err := getEnvUint16("UDP_PORT_MAX", 12000)
	if err != nil {
		return nil, fmt.Errorf("invalid UDP_PORT_MAX: %w", err)
	}
	cfg.UDPPortMax = portMax

	if cfg.UDPPortMin >= cfg.UDPPortMax {
		return nil, fmt.Errorf("UDP_PORT_MIN (%d) must be less than UDP_PORT_MAX (%d)", cfg.UDPPortMin, cfg.UDPPortMax)
	}

	// Parse HTTP port.
	httpPort, err := getEnvInt("HTTP_PORT", 4000)
	if err != nil {
		return nil, fmt.Errorf("invalid HTTP_PORT: %w", err)
	}
	cfg.HTTPPort = httpPort

	// Parse max session duration.
	maxDur, err := getEnvInt("MAX_SESSION_DURATION", 7200)
	if err != nil {
		return nil, fmt.Errorf("invalid MAX_SESSION_DURATION: %w", err)
	}
	cfg.MaxSessionDuration = time.Duration(maxDur) * time.Second

	// Parse reconnect timeout.
	reconTimeout, err := getEnvInt("RECONNECT_TIMEOUT", 30)
	if err != nil {
		return nil, fmt.Errorf("invalid RECONNECT_TIMEOUT: %w", err)
	}
	cfg.ReconnectTimeout = time.Duration(reconTimeout) * time.Second

	// Parse max concurrent sessions.
	maxSessions, err := getEnvInt("MAX_CONCURRENT_SESSIONS", 0)
	if err != nil {
		return nil, fmt.Errorf("invalid MAX_CONCURRENT_SESSIONS: %w", err)
	}
	cfg.MaxConcurrentSessions = maxSessions

	return cfg, nil
}

// Validate checks that required configuration values are set for production
// use. It returns a list of warnings for missing optional values.
func (c *Config) Validate() []string {
	var warnings []string
	if c.AuthToken == "" {
		warnings = append(warnings, "AUTH_TOKEN is not set; all API requests will be unauthenticated")
	}
	if c.RailsCallbackURL == "" {
		warnings = append(warnings, "RAILS_CALLBACK_URL is not set; callbacks to Rails will fail")
	}
	if len(c.STUNServers) == 0 {
		warnings = append(warnings, "No STUN servers configured; ICE candidate gathering may fail")
	}
	return warnings
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) (int, error) {
	str := os.Getenv(key)
	if str == "" {
		return defaultVal, nil
	}
	return strconv.Atoi(str)
}

func getEnvUint16(key string, defaultVal uint16) (uint16, error) {
	str := os.Getenv(key)
	if str == "" {
		return defaultVal, nil
	}
	v, err := strconv.ParseUint(str, 10, 16)
	if err != nil {
		return 0, err
	}
	return uint16(v), nil
}

func splitAndTrim(s string) []string {
	parts := strings.Split(s, ",")
	result := make([]string, 0, len(parts))
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}
