package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestJWTVerifies(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	a := &apns{cfg: config{keyID: "KEY123", teamID: "TEAM123"}, key: key}
	jwt, err := a.token()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("want 3 parts, got %d", len(parts))
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if len(sig) != 64 || !ecdsa.Verify(&key.PublicKey, sum[:], r, s) {
		t.Fatal("signature doesn't verify as raw r||s")
	}
	if again, _ := a.token(); again != jwt {
		t.Fatal("token should be reused within the hour")
	}
}

func TestSummaryPutsBlockedFirst(t *testing.T) {
	now := time.Now()
	s := &server{panes: map[string]*pane{
		"a": {block: "a", title: "old done", state: "done", changed: now.Add(-time.Hour)},
		"b": {block: "b", title: "working", state: "working", changed: now},
		"c": {block: "c", title: "blocked", state: "blocked", changed: now.Add(-time.Minute)},
		"d": {block: "d", title: "idle", state: "", changed: now},
		"e": {block: "e", title: "just done", state: "done", changed: now},
	}}
	c := s.summary()
	if c.Working != 1 || c.Blocked != 1 || c.Done != 1 {
		t.Fatalf("counts: %+v", c)
	}
	if len(c.Items) != 3 || c.Items[0].Title != "blocked" || c.Items[1].Title != "working" || c.Items[2].Title != "just done" {
		t.Fatalf("order: %+v", c.Items)
	}
	if headline(c) != "1 needs you · 1 working" {
		t.Fatalf("headline: %q", headline(c))
	}
}

func TestMutedPanesStayOut(t *testing.T) {
	now := time.Now()
	s := &server{muted: map[string]bool{"block:rev": true, "session:quiet": true}, panes: map[string]*pane{
		"block:rev": {block: "block:rev", session: "session:a", title: "REVIEWER", state: "working", changed: now},
		"block:q":   {block: "block:q", session: "session:quiet", title: "in a muted session", state: "blocked", changed: now},
		"block:b":   {block: "block:b", session: "session:a", title: "builder", state: "working", changed: now},
	}}
	c := s.summary()
	if c.Working != 1 || c.Blocked != 0 || len(c.Items) != 1 || c.Items[0].Title != "builder" {
		t.Fatalf("muted panes leaked into the summary: %+v", c)
	}
}

func TestHexToken(t *testing.T) {
	if !hexToken(strings.Repeat("ab", 32)) || hexToken("xyz") || hexToken(strings.Repeat("g", 64)) {
		t.Fatal("hexToken")
	}
}

func TestSummaryEndpoint(t *testing.T) {
	s := &server{muted: map[string]bool{}, panes: map[string]*pane{
		"block:a": {block: "block:a", title: "builder", state: "blocked", changed: time.Now()},
	}}
	rec := httptest.NewRecorder()
	s.summaryHandler(rec, httptest.NewRequest("GET", "/summary", nil))
	var c contentState
	if err := json.NewDecoder(rec.Body).Decode(&c); err != nil || c.Blocked != 1 || len(c.Items) != 1 || c.Items[0].Title != "builder" {
		t.Fatalf("summary: %v %+v", err, c)
	}
	post := httptest.NewRecorder()
	s.summaryHandler(post, httptest.NewRequest("POST", "/summary", nil))
	if post.Code != 405 {
		t.Fatalf("POST answered %d", post.Code)
	}
}

func TestOldActivityIsReplaced(t *testing.T) {
	now := time.Now()
	fresh := &device{ActivityToken: "ab", ActivityStart: now.Add(-time.Hour)}
	old := &device{ActivityToken: "ab", ActivityStart: now.Add(-8 * time.Hour)}
	unknown := &device{ActivityToken: "ab"} // registered before irex-push kept the start time
	none := &device{}
	if fresh.stale(now) || !old.stale(now) || !unknown.stale(now) || none.stale(now) {
		t.Fatal("stale")
	}
}

func TestRegisterKeepsActivityAge(t *testing.T) {
	s := &server{cfg: config{state: t.TempDir()}, devices: map[string]*device{}, dirty: make(chan struct{}, 1)}
	token := strings.Repeat("ab", 32)
	reg := func(body string) {
		rec := httptest.NewRecorder()
		s.register(rec, httptest.NewRequest("POST", "/register", strings.NewReader(body)))
		if rec.Code != 204 {
			t.Fatalf("register answered %d", rec.Code)
		}
	}
	act := strings.Repeat("cd", 32)
	reg(`{"token":"` + token + `","env":"sandbox","activity_token":"` + act + `"}`)
	first := s.devices[token].ActivityStart
	if first.IsZero() {
		t.Fatal("no start time")
	}
	reg(`{"token":"` + token + `","env":"sandbox","activity_token":"` + act + `"}`) // the same one again
	if !s.devices[token].ActivityStart.Equal(first) {
		t.Fatal("re-registering the same activity reset its age")
	}
	reg(`{"token":"` + token + `","env":"sandbox","no_activity":true}`)
	if s.devices[token].ActivityToken != "" {
		t.Fatal("an ended activity kept its token")
	}
}
