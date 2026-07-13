package config

import (
	"encoding/base64"
	"fmt"
	"log/slog"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	HTTPAddress      string
	DatabaseURL      string
	PublicBaseURL    string
	AllowedOrigins   map[string]struct{}
	ViewerSigningKey []byte
	LogLevel         slog.Level
	TrustedProxies   []netip.Prefix
	DatabaseMaxConns int32
	RequestTimeout   time.Duration
}

func Load() (Config, error) {
	databaseURL, err := secret("RUNSYNC_DATABASE_URL")
	if err != nil {
		return Config{}, err
	}
	c := Config{HTTPAddress: env("RUNSYNC_HTTP_ADDRESS", ":8080"), DatabaseURL: databaseURL, AllowedOrigins: map[string]struct{}{}, DatabaseMaxConns: 10, RequestTimeout: 10 * time.Second}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("RUNSYNC_DATABASE_URL is required")
	}
	c.PublicBaseURL = os.Getenv("RUNSYNC_PUBLIC_BASE_URL")
	if u, err := url.Parse(c.PublicBaseURL); err != nil || u.Scheme != "https" || u.Host == "" {
		return c, fmt.Errorf("RUNSYNC_PUBLIC_BASE_URL must be an https URL")
	}
	for _, origin := range split(os.Getenv("RUNSYNC_ALLOWED_ORIGINS")) {
		u, err := url.Parse(origin)
		if err != nil || u.Scheme == "" || u.Host == "" || u.Path != "" {
			return c, fmt.Errorf("invalid allowed origin %q", origin)
		}
		c.AllowedOrigins[origin] = struct{}{}
	}
	signingValue, err := secret("RUNSYNC_VIEWER_TOKEN_SIGNING_KEY")
	if err != nil {
		return c, err
	}
	key, err := base64.StdEncoding.DecodeString(signingValue)
	if err != nil || len(key) < 32 {
		return c, fmt.Errorf("RUNSYNC_VIEWER_TOKEN_SIGNING_KEY must be base64 encoding of at least 32 bytes")
	}
	c.ViewerSigningKey = key
	if err := c.LogLevel.UnmarshalText([]byte(env("RUNSYNC_LOG_LEVEL", "info"))); err != nil {
		return c, fmt.Errorf("RUNSYNC_LOG_LEVEL: %w", err)
	}
	for _, raw := range split(os.Getenv("RUNSYNC_TRUSTED_PROXY_CIDRS")) {
		p, err := netip.ParsePrefix(raw)
		if err != nil {
			return c, fmt.Errorf("invalid trusted proxy CIDR %q", raw)
		}
		c.TrustedProxies = append(c.TrustedProxies, p)
	}
	if raw := os.Getenv("RUNSYNC_DATABASE_MAX_CONNS"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 100 {
			return c, fmt.Errorf("RUNSYNC_DATABASE_MAX_CONNS must be 1..100")
		}
		c.DatabaseMaxConns = int32(n)
	}
	return c, nil
}

func env(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
func split(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func secret(key string) (string, error) {
	if value := os.Getenv(key); value != "" {
		return value, nil
	}
	if path := os.Getenv(key + "_FILE"); path != "" {
		value, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read %s_FILE: %w", key, err)
		}
		return strings.TrimSpace(string(value)), nil
	}
	return "", nil
}
