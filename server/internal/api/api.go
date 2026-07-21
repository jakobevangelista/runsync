package api

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/ingest"
	"github.com/jakobevangelista/runsync/server/internal/live"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

const maxBody = 256 << 10

type Server struct {
	pool    *pgxpool.Pool
	ingest  *ingest.Store
	live    liveStore
	hub     *live.Hub
	key     []byte
	origins map[string]struct{}
	proxies []netip.Prefix
	logger  *slog.Logger
	limiter *limiter
	ingests *userLocks
}

type liveStore interface {
	Channel(context.Context, uuid.UUID, string) (live.Channel, error)
	Bootstrap(context.Context, live.Channel, time.Time) (live.Bootstrap, error)
	Snapshot(context.Context, live.Channel, time.Time) (live.Snapshot, error)
	Route(context.Context, live.Channel, time.Time) (live.Route, error)
	Replay(context.Context, live.Channel, uuid.UUID, int) ([]live.SampleView, bool, error)
}

func New(pool *pgxpool.Pool, key []byte, origins map[string]struct{}, proxies []netip.Prefix, logger *slog.Logger) *Server {
	return &Server{pool: pool, ingest: ingest.New(pool), live: live.NewStore(pool), hub: live.NewHub(32), key: key, origins: origins, proxies: proxies, logger: logger, limiter: newLimiter(120, 200), ingests: newUserLocks()}
}
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("POST /v1/telemetry/batches", s.batch)
	mux.HandleFunc("POST /v1/viewer-tokens", s.viewerToken)
	mux.HandleFunc("GET /v1/channels/{slug}/bootstrap", s.bootstrap)
	mux.HandleFunc("GET /v1/channels/{slug}/snapshot", s.snapshot)
	mux.HandleFunc("GET /v1/channels/{slug}/route", s.route)
	mux.HandleFunc("GET /v1/channels/{slug}/stream", s.stream)
	return s.cors(s.logging(mux))
}
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]string{"status": "ok"})
}
func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.pool.Ping(ctx); err != nil {
		writeError(w, 503, "not_ready", "service is not ready")
		return
	}
	writeJSON(w, 200, map[string]string{"status": "ok"})
}
func (s *Server) batch(w http.ResponseWriter, r *http.Request) {
	p, ok := s.serviceAuth(w, r, "telemetry:write")
	if !ok {
		return
	}
	if !s.limiter.Allow("credential:"+p.CredentialID.String()) || !s.limiter.Allow("ip:"+s.clientIP(r)) {
		w.Header().Set("Retry-After", "1")
		writeError(w, 429, "rate_limited", "request rate exceeded")
		return
	}
	var b telemetry.Batch
	if !decode(w, r, &b) {
		return
	}
	now := time.Now().UTC()
	if err := b.Validate(now); err != nil {
		var validation *telemetry.ValidationError
		if errors.As(err, &validation) {
			writeAPIError(w, http.StatusUnprocessableEntity, string(validation.Code), validation.Error(), validation.EnvelopeID)
		} else {
			writeAPIError(w, http.StatusUnprocessableEntity, string(telemetry.ValidationInvalidRequest), "invalid telemetry request", nil)
		}
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	unlock, err := s.ingests.Lock(ctx, p.UserID)
	if err != nil {
		writeError(w, http.StatusRequestTimeout, "request_timeout", "request canceled while waiting to ingest")
		return
	}
	result, err := s.ingest.Ingest(ctx, p, b, now)
	if err != nil {
		unlock()
		if status, code, message, envelopeID, ok := ingestRejectionResponse(err); ok {
			writeAPIError(w, status, code, message, envelopeID)
		} else {
			s.logger.Error("ingest failed", "category", "store_error")
			writeError(w, 500, "internal_error", "internal server error")
		}
		return
	}
	s.publishIngest(result)
	unlock()
	writeJSON(w, 200, map[string]any{"acknowledgedEnvelopeIds": result.Acknowledged, "serverTime": now})
}
func (s *Server) publishIngest(result ingest.Result) {
	for _, event := range result.Transitions {
		for _, channel := range result.Channels[event.Envelope.ActivityID] {
			s.hub.Publish(channel, live.Message{Kind: "activity", Event: event})
		}
	}
	events := append([]telemetry.Event(nil), result.Events...)
	slices.SortFunc(events, func(a, b telemetry.Event) int {
		return cmp.Compare(a.IngestCursor, b.IngestCursor)
	})
	for _, event := range events {
		for _, channel := range result.Channels[event.Envelope.ActivityID] {
			s.hub.Publish(channel, live.Message{Kind: "sample", Event: event})
		}
	}
}

func (s *Server) bootstrap(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.readChannel(w, r)
	if !ok {
		return
	}
	out, err := s.live.Bootstrap(r.Context(), c, time.Now().UTC())
	if err != nil {
		s.channelError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

type viewerRequest struct {
	ChannelSlug     string `json:"channelSlug"`
	LifetimeSeconds int    `json:"lifetimeSeconds"`
}

func (s *Server) viewerToken(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	p, ok := s.serviceAuth(w, r, "channels:read")
	if !ok {
		return
	}
	var req viewerRequest
	if !decode(w, r, &req) {
		return
	}
	if req.LifetimeSeconds == 0 {
		req.LifetimeSeconds = 300
	}
	if req.LifetimeSeconds < 1 || req.LifetimeSeconds > 300 {
		writeError(w, 422, "validation_failed", "lifetimeSeconds must be 1..300")
		return
	}
	c, err := s.live.Channel(r.Context(), p.UserID, req.ChannelSlug)
	if errors.Is(err, live.ErrNotFound) {
		writeError(w, 404, "not_found", "channel not found")
		return
	}
	if err != nil {
		writeError(w, 500, "internal_error", "internal server error")
		return
	}
	now := time.Now().UTC()
	claims := auth.ViewerClaims{ChannelID: c.ID, UserID: c.UserID, Slug: c.Slug, Policy: c.Policy, Decimals: c.Decimals, IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Duration(req.LifetimeSeconds) * time.Second).Unix(), Scope: "channel:live"}
	token, err := auth.SignViewer(s.key, claims)
	if err != nil {
		writeError(w, 500, "internal_error", "internal server error")
		return
	}
	writeJSON(w, 201, map[string]any{"token": token, "expiresAt": time.Unix(claims.ExpiresAt, 0).UTC()})
}
func (s *Server) snapshot(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.readChannel(w, r)
	if !ok {
		return
	}
	out, err := s.live.Snapshot(r.Context(), c, time.Now().UTC())
	if err != nil {
		writeError(w, 500, "internal_error", "internal server error")
		return
	}
	writeJSON(w, 200, out)
}
func (s *Server) route(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.readChannel(w, r)
	if !ok {
		return
	}
	out, err := s.live.Route(r.Context(), c, time.Now().UTC())
	if err != nil {
		s.logger.Error("route lookup failed", "error", err)
		writeError(w, 500, "internal_error", "internal server error")
		return
	}
	writeJSON(w, 200, out)
}
func (s *Server) readChannel(w http.ResponseWriter, r *http.Request) (live.Channel, bool) {
	slug := r.PathValue("slug")
	token := bearer(r)
	if strings.HasPrefix(token, "rs_") {
		p, ok := s.authenticate(w, r, token, "channels:read")
		if !ok {
			return live.Channel{}, false
		}
		c, err := s.live.Channel(r.Context(), p.UserID, slug)
		if err != nil {
			s.channelError(w, err)
			return live.Channel{}, false
		}
		return c, true
	}
	claims, err := auth.VerifyViewer(s.key, token, time.Now())
	if err != nil || claims.Slug != slug {
		unauthorized(w)
		return live.Channel{}, false
	}
	c, err := s.live.Channel(r.Context(), claims.UserID, slug)
	if err != nil || c.ID != claims.ChannelID {
		unauthorized(w)
		return live.Channel{}, false
	}
	clampChannel(&c, claims)
	return c, true
}
func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	claims, err := auth.VerifyViewer(s.key, bearer(r), time.Now())
	if err != nil || claims.Slug != r.PathValue("slug") {
		unauthorized(w)
		return
	}
	sub := s.hub.Subscribe(claims.ChannelID)
	defer sub.Close()
	c, err := s.live.Channel(r.Context(), claims.UserID, claims.Slug)
	if err != nil || c.ID != claims.ChannelID {
		unauthorized(w)
		return
	}
	clampChannel(&c, claims)
	_, ok := w.(http.Flusher)
	if !ok {
		writeError(w, 500, "stream_unsupported", "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	controller := http.NewResponseController(w)
	flush := func() error {
		if err := controller.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return err
		}
		if err := controller.Flush(); err != nil {
			return err
		}
		if err := controller.SetWriteDeadline(time.Time{}); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return err
		}
		return nil
	}
	send := func(event, id string, value any) error {
		if err := controller.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return err
		}
		if err := writeSSE(w, event, id, value); err != nil {
			return err
		}
		if err := controller.Flush(); err != nil {
			return err
		}
		if err := controller.SetWriteDeadline(time.Time{}); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return err
		}
		return nil
	}
	replayed := map[uuid.UUID]struct{}{}
	if raw := r.Header.Get("Last-Event-ID"); raw != "" {
		id, e := uuid.Parse(raw)
		if e != nil {
			_ = send("reset", "", map[string]string{"reason": "invalid_replay_position"})
			return
		} else {
			items, reset, e := s.live.Replay(r.Context(), c, id, 200)
			if e != nil {
				return
			}
			if reset {
				_ = send("reset", "", map[string]string{"reason": "replay_unavailable"})
				return
			} else {
				for _, item := range items {
					replayed[item.EnvelopeID] = struct{}{}
					if send("sample", item.EnvelopeID.String(), item) != nil {
						return
					}
				}
			}
		}
	}
	if err := flush(); err != nil {
		return
	}
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	expires := time.NewTimer(time.Until(time.Unix(claims.ExpiresAt, 0)))
	defer expires.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-expires.C:
			return
		case <-heartbeat.C:
			if err := controller.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
				return
			}
			if _, err := io.WriteString(w, ": heartbeat\n\n"); err != nil {
				return
			}
			if err := controller.Flush(); err != nil {
				return
			}
			if err := controller.SetWriteDeadline(time.Time{}); err != nil && !errors.Is(err, http.ErrNotSupported) {
				return
			}
		case message, open := <-sub.C:
			if !open {
				return
			}
			if message.Kind == "sample" {
				if _, ok := replayed[message.Event.Envelope.EnvelopeID]; ok {
					delete(replayed, message.Event.Envelope.EnvelopeID)
					continue
				}
			}
			current, e := s.live.Channel(r.Context(), claims.UserID, claims.Slug)
			if e != nil {
				return
			}
			clampChannel(&current, claims)
			event := live.EventView(message.Event, current.Policy, current.Decimals)
			if send(message.Kind, event.EnvelopeID.String(), event) != nil {
				return
			}
		}
	}
}
func (s *Server) serviceAuth(w http.ResponseWriter, r *http.Request, scope string) (auth.Principal, bool) {
	return s.authenticate(w, r, bearer(r), scope)
}
func (s *Server) authenticate(w http.ResponseWriter, r *http.Request, token, scope string) (auth.Principal, bool) {
	p, err := auth.Authenticate(r.Context(), s.pool, token, scope)
	if err != nil {
		unauthorized(w)
		return p, false
	}
	return p, true
}
func bearer(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(value, "Bearer "))
}
func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	if ct := strings.Split(r.Header.Get("Content-Type"), ";")[0]; ct != "application/json" {
		writeError(w, 415, "unsupported_media_type", "Content-Type must be application/json")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var max *http.MaxBytesError
		if errors.As(err, &max) {
			writeError(w, 413, "body_too_large", "request body exceeds 256 KiB")
		} else {
			writeError(w, 400, "invalid_json", "invalid JSON request")
		}
		return false
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeError(w, 400, "invalid_json", "request must contain one JSON value")
		return false
	}
	return true
}
func (s *Server) channelError(w http.ResponseWriter, err error) {
	if errors.Is(err, live.ErrNotFound) {
		writeError(w, 404, "not_found", "channel not found")
	} else {
		writeError(w, 500, "internal_error", "internal server error")
	}
}
func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="runsync"`)
	writeError(w, 401, "unauthorized", "valid bearer credentials are required")
}
func ingestRejectionResponse(err error) (int, string, string, *uuid.UUID, bool) {
	var rejection *ingest.RejectionError
	if !errors.As(err, &rejection) {
		return 0, "", "", nil, false
	}
	switch rejection.Code {
	case ingest.CodeEnvelopeConflict:
		return http.StatusConflict, string(rejection.Code), "envelope conflicts with existing telemetry", rejection.EnvelopeID, true
	case ingest.CodeInstallationOwnershipConflict:
		return http.StatusForbidden, string(rejection.Code), "installation is not available to this credential", rejection.EnvelopeID, true
	case ingest.CodeEnvelopeOwnershipConflict:
		return http.StatusForbidden, string(rejection.Code), "envelope is not available to this credential", rejection.EnvelopeID, true
	default:
		return 0, "", "", nil, false
	}
}
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeAPIError(w, status, code, message, nil)
}
func writeAPIError(w http.ResponseWriter, status int, code, message string, envelopeID *uuid.UUID) {
	writeJSON(w, status, map[string]any{"error": struct {
		Code       string     `json:"code"`
		Message    string     `json:"message"`
		EnvelopeID *uuid.UUID `json:"envelopeId"`
		Retryable  bool       `json:"retryable"`
	}{Code: code, Message: message, EnvelopeID: envelopeID, Retryable: status == http.StatusRequestTimeout || status == http.StatusTooEarly || status == http.StatusTooManyRequests || status >= 500}})
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func writeSSE(w io.Writer, event, id string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	var out strings.Builder
	if id != "" {
		fmt.Fprintf(&out, "id: %s\n", id)
	}
	fmt.Fprintf(&out, "event: %s\ndata: %s\n\n", event, data)
	_, err = io.WriteString(w, out.String())
	return err
}
func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			if _, ok := s.origins[origin]; !ok {
				writeError(w, 403, "origin_forbidden", "origin is not allowed")
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Last-Event-ID")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Max-Age", "600")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(v int) { w.status = v; w.ResponseWriter.WriteHeader(v) }
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (s *Server) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		s.logger.Info("request", "method", r.Method, "path", r.URL.Path, "status", sw.status, "duration_ms", time.Since(start).Milliseconds())
	})
}

type limiter struct {
	mu          sync.Mutex
	rate, burst float64
	entries     map[string]*limitEntry
}

type userLocks struct {
	mu    sync.Mutex
	locks map[uuid.UUID]*userLock
}

type userLock struct {
	token chan struct{}
	refs  int
}

func newUserLocks() *userLocks { return &userLocks{locks: map[uuid.UUID]*userLock{}} }

func (l *userLocks) Lock(ctx context.Context, user uuid.UUID) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	l.mu.Lock()
	lock := l.locks[user]
	if lock == nil {
		lock = &userLock{token: make(chan struct{}, 1)}
		lock.token <- struct{}{}
		l.locks[user] = lock
	}
	lock.refs++
	l.mu.Unlock()
	select {
	case <-ctx.Done():
		l.releaseRef(user, lock)
		return nil, ctx.Err()
	case <-lock.token:
		var once sync.Once
		return func() {
			once.Do(func() {
				l.mu.Lock()
				lock.token <- struct{}{}
				lock.refs--
				if lock.refs == 0 {
					delete(l.locks, user)
				}
				l.mu.Unlock()
			})
		}, nil
	}
}

func (l *userLocks) releaseRef(user uuid.UUID, lock *userLock) {
	l.mu.Lock()
	lock.refs--
	if lock.refs == 0 {
		delete(l.locks, user)
	}
	l.mu.Unlock()
}

type limitEntry struct {
	tokens float64
	at     time.Time
}

func newLimiter(perMinute, burst int) *limiter {
	return &limiter{rate: float64(perMinute) / 60, burst: float64(burst), entries: map[string]*limitEntry{}}
}
func (l *limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	e := l.entries[key]
	if e == nil {
		e = &limitEntry{tokens: l.burst, at: now}
		l.entries[key] = e
	}
	e.tokens = min(l.burst, e.tokens+now.Sub(e.at).Seconds()*l.rate)
	e.at = now
	if e.tokens < 1 {
		return false
	}
	e.tokens--
	return true
}
func (s *Server) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	remote, err := netip.ParseAddr(host)
	if err == nil {
		for _, p := range s.proxies {
			if p.Contains(remote) {
				if forwarded := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-For"), ",")[0]); forwarded != "" {
					if ip, e := netip.ParseAddr(forwarded); e == nil {
						return ip.String()
					}
				}
			}
		}
	}
	return host
}
func clampChannel(c *live.Channel, claims auth.ViewerClaims) {
	rank := map[string]int{"hidden": 0, "rounded": 1, "precise": 2}
	if rank[claims.Policy] < rank[c.Policy] {
		c.Policy = claims.Policy
		c.Decimals = claims.Decimals
	} else if c.Policy == "rounded" && claims.Policy == "rounded" && claims.Decimals != nil && (c.Decimals == nil || *claims.Decimals < *c.Decimals) {
		c.Decimals = claims.Decimals
	}
}
