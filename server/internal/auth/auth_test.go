package auth

import (
	"bytes"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestGenerateToken(t *testing.T) {
	a, ap, ah, err := GenerateToken()
	if err != nil {
		t.Fatal(err)
	}
	b, bp, bh, err := GenerateToken()
	if err != nil {
		t.Fatal(err)
	}
	if a == b || ap == bp || bytes.Equal(ah, bh) {
		t.Fatal("tokens must be unique")
	}
	if len(ah) != 32 || !bytes.Equal(ah, Hash(a)) {
		t.Fatal("unexpected digest")
	}
}
func TestViewerToken(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 32)
	now := time.Now().Truncate(time.Second)
	want := ViewerClaims{ChannelID: uuid.New(), UserID: uuid.New(), Slug: "live", Policy: "hidden", IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Minute).Unix(), Scope: "channel:live"}
	token, err := SignViewer(key, want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := VerifyViewer(key, token, now)
	if err != nil || got.ChannelID != want.ChannelID {
		t.Fatalf("verify: %#v %v", got, err)
	}
	if _, err = VerifyViewer(key, token, now.Add(2*time.Minute)); err == nil {
		t.Fatal("expired token accepted")
	}
	token = token[:len(token)-1] + "x"
	if _, err = VerifyViewer(key, token, now); err == nil {
		t.Fatal("tampered token accepted")
	}
}
