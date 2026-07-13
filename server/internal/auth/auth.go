package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrUnauthorized = errors.New("unauthorized")

type Principal struct {
	CredentialID, UserID uuid.UUID
	Scopes               map[string]bool
	InstallationID       *uuid.UUID
}

func GenerateToken() (token, prefix string, hash []byte, err error) {
	raw := make([]byte, 32)
	if _, err = rand.Read(raw); err != nil {
		return "", "", nil, err
	}
	token = "rs_" + base64.RawURLEncoding.EncodeToString(raw)
	prefix = token[:11]
	sum := sha256.Sum256([]byte(token))
	return token, prefix, sum[:], nil
}

func Hash(token string) []byte { sum := sha256.Sum256([]byte(token)); return sum[:] }

func Authenticate(ctx context.Context, pool *pgxpool.Pool, token, required string) (Principal, error) {
	var p Principal
	if len(token) < 11 || !strings.HasPrefix(token, "rs_") {
		return p, ErrUnauthorized
	}
	var stored []byte
	var scopes []string
	var expires, revoked, disabled *time.Time
	err := pool.QueryRow(ctx, `SELECT c.id,c.user_id,c.installation_id,c.token_hash,c.scopes,c.expires_at,c.revoked_at,u.disabled_at FROM api_credentials c JOIN users u ON u.id=c.user_id WHERE c.token_prefix=$1`, token[:11]).Scan(&p.CredentialID, &p.UserID, &p.InstallationID, &stored, &scopes, &expires, &revoked, &disabled)
	if err != nil || subtle.ConstantTimeCompare(stored, Hash(token)) != 1 || revoked != nil || disabled != nil || (expires != nil && !expires.After(time.Now())) {
		return Principal{}, ErrUnauthorized
	}
	p.Scopes = map[string]bool{}
	for _, scope := range scopes {
		p.Scopes[scope] = true
	}
	if !p.Scopes[required] {
		return Principal{}, ErrUnauthorized
	}
	_, _ = pool.Exec(ctx, `UPDATE api_credentials SET last_used_at=now() WHERE id=$1`, p.CredentialID)
	return p, nil
}

type ViewerClaims struct {
	ChannelID uuid.UUID `json:"channelId"`
	UserID    uuid.UUID `json:"userId"`
	Slug      string    `json:"slug"`
	Policy    string    `json:"policy"`
	Decimals  *int16    `json:"decimals,omitempty"`
	IssuedAt  int64     `json:"iat"`
	ExpiresAt int64     `json:"exp"`
	Scope     string    `json:"scope"`
}

func SignViewer(key []byte, claims ViewerClaims) (string, error) {
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(encoded))
	return "rsv1." + encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func VerifyViewer(key []byte, token string, now time.Time) (ViewerClaims, error) {
	var c ViewerClaims
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] != "rsv1" {
		return c, ErrUnauthorized
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return c, ErrUnauthorized
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(parts[1]))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return c, ErrUnauthorized
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(payload, &c) != nil || c.Scope != "channel:live" || c.ExpiresAt <= now.Unix() || c.IssuedAt > now.Add(time.Minute).Unix() {
		return ViewerClaims{}, ErrUnauthorized
	}
	return c, nil
}
