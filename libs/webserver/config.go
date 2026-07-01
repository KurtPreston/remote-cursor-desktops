package webserver

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/KurtPreston/wsm/libs/api"
)

// Mode selects how the daemon binds and secures its listener.
type Mode string

const (
	// ModeLocal binds loopback over plain HTTP; Bearer token required.
	ModeLocal Mode = "local"
	// ModeSSH is loopback + HTTP reached through an SSH reverse tunnel; token required.
	ModeSSH Mode = "ssh"
	// ModeNetwork binds a configurable interface over HTTPS; explicit opt-in, token required.
	ModeNetwork Mode = "network"
)

// TLSConfig holds the certificate/key paths required in network mode.
type TLSConfig struct {
	Cert string `json:"cert"`
	Key  string `json:"key"`
}

// IDEProfile describes how to open a workspace in a particular IDE. Profiles
// make the /open behavior config-driven rather than hardcoded.
type IDEProfile struct {
	// Process is the OS process/app name used to match windows (e.g. Cursor).
	Process string `json:"process"`
	// Exe is an explicit launcher path. Empty means per-OS auto-detection.
	Exe string `json:"exe"`
	// LaunchArgs is the argv template; {uri} is replaced with the resolved URI.
	LaunchArgs []string `json:"launchArgs"`
	// LocalURI templates the folder URI for a local path ({path}).
	LocalURI string `json:"localUri"`
	// RemoteURI templates the folder URI for a remote path ({host},{path}).
	RemoteURI string `json:"remoteUri"`
}

// Config is the wsmd runtime configuration.
type Config struct {
	Mode       Mode                  `json:"mode"`
	Bind       string                `json:"bind"`
	Port       int                   `json:"port"`
	Token      string                `json:"token"`
	TLS        TLSConfig             `json:"tls"`
	IDE        string                `json:"ide"`
	Profiles   map[string]IDEProfile `json:"profiles"`
	CORSOrigin string                `json:"corsOrigin,omitempty"`
}

// DefaultProfiles returns the out-of-the-box IDE profiles (Cursor + VSCode).
func DefaultProfiles() map[string]IDEProfile {
	return map[string]IDEProfile{
		"cursor": {
			Process:    "Cursor",
			LaunchArgs: []string{"--new-window", "--folder-uri", "{uri}"},
			LocalURI:   "file://{path}",
			RemoteURI:  "vscode-remote://ssh-remote+{host}{path}",
		},
		"vscode": {
			Process:    "Code",
			LaunchArgs: []string{"--new-window", "--folder-uri", "{uri}"},
			LocalURI:   "file://{path}",
			RemoteURI:  "vscode-remote://ssh-remote+{host}{path}",
		},
	}
}

// Default returns a config with sane defaults for local mode.
func Default() Config {
	return Config{
		Mode:       ModeLocal,
		Bind:       "127.0.0.1",
		Port:       api.DefaultPort,
		IDE:        "cursor",
		CORSOrigin: "*",
		Profiles:   DefaultProfiles(),
	}
}

// Load reads a config from path, or (when path is empty) from the discovery
// chain: $WSM_CONFIG, ./wsm.config.json(c), $HOME/.config/wsm/config.json(c).
// File values overlay the defaults, so the built-in profiles remain available
// unless overridden. $WSM_TOKEN, when set, overrides the token.
func Load(path string) (Config, error) {
	cfg := Default()

	if path == "" {
		path = discoverConfigPath()
	}
	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return cfg, fmt.Errorf("read config %s: %w", path, err)
		}
		if err := unmarshalJSONC(data, &cfg); err != nil {
			return cfg, fmt.Errorf("parse config %s: %w", path, err)
		}
	}

	if tok := os.Getenv("WSM_TOKEN"); tok != "" {
		cfg.Token = tok
	}
	if cfg.Mode == "" {
		cfg.Mode = ModeLocal
	}
	if cfg.Bind == "" {
		cfg.Bind = "127.0.0.1"
	}
	if cfg.Port == 0 {
		cfg.Port = api.DefaultPort
	}
	if cfg.IDE == "" {
		cfg.IDE = "cursor"
	}
	if cfg.CORSOrigin == "" {
		cfg.CORSOrigin = "*"
	}
	if len(cfg.Profiles) == 0 {
		cfg.Profiles = DefaultProfiles()
	}
	return cfg, nil
}

func discoverConfigPath() string {
	if p := os.Getenv("WSM_CONFIG"); p != "" {
		return p
	}
	candidates := []string{"wsm.config.jsonc", "wsm.config.json"}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".config", "wsm", "config.jsonc"),
			filepath.Join(home, ".config", "wsm", "config.json"),
		)
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// Validate enforces the mode invariants and that the selected IDE resolves.
func (c Config) Validate() error {
	if c.Token == "" {
		return errors.New("token is required in all modes (set config \"token\" or $WSM_TOKEN)")
	}
	switch c.Mode {
	case ModeLocal, ModeSSH:
		if !isLoopback(c.Bind) {
			return fmt.Errorf("mode %q requires a loopback bind, got %q; use mode \"network\" (with TLS) for a routable interface", c.Mode, c.Bind)
		}
	case ModeNetwork:
		if c.TLS.Cert == "" || c.TLS.Key == "" {
			return errors.New("mode \"network\" requires tls.cert and tls.key (HTTPS is mandatory off loopback)")
		}
	default:
		return fmt.Errorf("unknown mode %q (want \"local\", \"ssh\", or \"network\")", c.Mode)
	}
	if _, ok := c.ActiveProfile(); !ok {
		return fmt.Errorf("ide %q has no matching entry in profiles", c.IDE)
	}
	return nil
}

// ActiveProfile returns the profile selected by cfg.IDE.
func (c Config) ActiveProfile() (IDEProfile, bool) {
	p, ok := c.Profiles[c.IDE]
	return p, ok
}

// Addr is the host:port the server listens on.
func (c Config) Addr() string {
	return fmt.Sprintf("%s:%d", c.Bind, c.Port)
}

// UsesTLS reports whether the listener should serve HTTPS.
func (c Config) UsesTLS() bool { return c.Mode == ModeNetwork }

// isLoopback reports whether bind refers to the loopback interface only.
func isLoopback(bind string) bool {
	switch strings.ToLower(strings.TrimSpace(bind)) {
	case "", "localhost":
		return true
	}
	ip := net.ParseIP(bind)
	return ip != nil && ip.IsLoopback()
}

// resolveURI computes the folder URI for an open request using the profile
// templates. A client-supplied URI wins; otherwise remote vs. local is chosen
// by the presence of a host.
func resolveURI(p IDEProfile, req api.OpenRequest) string {
	if req.URI != "" {
		return req.URI
	}
	tmpl := p.LocalURI
	if req.Host != "" {
		tmpl = p.RemoteURI
	}
	return expand(tmpl, map[string]string{"host": req.Host, "path": req.Path})
}

func expand(tmpl string, kv map[string]string) string {
	for k, v := range kv {
		tmpl = strings.ReplaceAll(tmpl, "{"+k+"}", v)
	}
	return tmpl
}

// leafOf returns the final path segment, tolerating / and \ separators.
func leafOf(p string) string {
	p = strings.TrimRight(p, "/\\")
	if i := strings.LastIndexAny(p, "/\\"); i >= 0 {
		return p[i+1:]
	}
	return p
}
