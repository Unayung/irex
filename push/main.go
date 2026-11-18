// irex-push watches Rex servers for agents that need you or finish, and tells irex
// through Apple Push: a notification, and one Live Activity that sums up every agent.
//
// It reads `rex events --all --json` from the local server and from each host in
// `rex hosts`, and takes irex's push tokens over HTTP (POST /register). Configure it
// with IREX_KEY_ID, IREX_TEAM_ID, IREX_KEY_FILE (the APNs .p8), and IREX_TOPIC (the
// app's bundle ID); IREX_LISTEN defaults to 127.0.0.1:7298.
package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---- configuration

type config struct {
	keyID, teamID, keyFile, topic, listen, state string
}

func loadConfig() config {
	home, _ := os.UserHomeDir()
	c := config{
		keyID:   os.Getenv("IREX_KEY_ID"),
		teamID:  os.Getenv("IREX_TEAM_ID"),
		keyFile: os.Getenv("IREX_KEY_FILE"),
		topic:   os.Getenv("IREX_TOPIC"),
		listen:  os.Getenv("IREX_LISTEN"),
		state:   filepath.Join(home, ".local/state/irex-push"),
	}
	if c.listen == "" {
		c.listen = "127.0.0.1:7298"
	}
	if c.teamID == "" || c.topic == "" {
		log.Fatal("set IREX_TEAM_ID and IREX_TOPIC, and IREX_KEY_ID and IREX_KEY_FILE to send")
	}
	return c
}

// ---- Apple Push

type apns struct {
	cfg    config
	key    *ecdsa.PrivateKey
	client *http.Client
	mu     sync.Mutex
	jwt    string
	jwtAt  time.Time
}

func newAPNs(cfg config) (*apns, error) {
	raw, err := os.ReadFile(cfg.keyFile)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("the key file isn't PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("the key isn't an EC key")
	}
	// net/http speaks HTTP/2 to TLS servers that offer it, as APNs does.
	return &apns{cfg: cfg, key: ec, client: &http.Client{Timeout: 15 * time.Second}}, nil
}

// token is the provider JWT; Apple wants it reused for up to an hour.
func (a *apns) token() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && time.Since(a.jwtAt) < 50*time.Minute {
		return a.jwt, nil
	}
	enc := base64.RawURLEncoding
	head := enc.EncodeToString([]byte(fmt.Sprintf(`{"alg":"ES256","kid":%q}`, a.cfg.keyID)))
	now := time.Now()
	claims := enc.EncodeToString([]byte(fmt.Sprintf(`{"iss":%q,"iat":%d}`, a.cfg.teamID, now.Unix())))
	sum := sha256.Sum256([]byte(head + "." + claims))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64) // JOSE wants r and s as two fixed 32-byte halves
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt, a.jwtAt = head+"."+claims+"."+enc.EncodeToString(sig), now
	return a.jwt, nil
}

var errGone = errors.New("token no longer valid")

// send posts one push. kind is "alert" or "liveactivity".
func (a *apns) send(env, deviceToken, kind string, priority int, payload any) error {
	if a.key == nil {
		return errors.New("no APNs key yet")
	}
	body, _ := json.Marshal(payload)
	host := "https://api.push.apple.com"
	if env == "sandbox" {
		host = "https://api.sandbox.push.apple.com"
	}
	req, _ := http.NewRequest("POST", host+"/3/device/"+deviceToken, bytes.NewReader(body))
	jwt, err := a.token()
	if err != nil {
		return err
	}
	topic := a.cfg.topic
	if kind == "liveactivity" {
		topic += ".push-type.liveactivity"
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", kind)
	req.Header.Set("apns-priority", fmt.Sprint(priority))
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return nil
	}
	msg, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == 410 || bytes.Contains(msg, []byte("BadDeviceToken")) {
		return errGone
	}
	return fmt.Errorf("apns %d: %s", resp.StatusCode, msg)
}

// ---- devices

type device struct {
	Token         string    `json:"token"`
	Env           string    `json:"env"`                      // sandbox or production
	StartToken    string    `json:"start_token,omitempty"`    // starts the Live Activity by push
	ActivityToken string    `json:"activity_token,omitempty"` // updates the one that's running
	Updated       time.Time `json:"updated"`
	started       time.Time // when irex-push last asked this device to start the Live Activity
}

// ---- agents

type pane struct {
	host, session, block string
	title, state, msg    string
	changed              time.Time
}

// item is one row of the Live Activity; ContentState in the app has the same shape.
type item struct {
	Title  string `json:"title"`
	State  string `json:"state"`
	Detail string `json:"detail"`
	Block  string `json:"block"`
}

type contentState struct {
	Working int    `json:"working"`
	Blocked int    `json:"blocked"`
	Done    int    `json:"done"`
	Items   []item `json:"items"`
}

type server struct {
	cfg     config
	push    *apns
	mu      sync.Mutex
	panes   map[string]*pane // block ID → pane
	devices map[string]*device
	muted   map[string]bool // session or block IDs that stay quiet: no alerts, not in the Live Activity
	// The Live Activity: whether one runs, what it last showed, and when anything last moved.
	active     bool
	shown      contentState
	lastActive time.Time
	dirty      chan struct{}
}

func (s *server) devicesFile() string { return filepath.Join(s.cfg.state, "devices.json") }
func (s *server) mutedFile() string   { return filepath.Join(s.cfg.state, "muted.json") }

func (s *server) loadMuted() {
	s.muted = map[string]bool{}
	var ids []string
	if raw, err := os.ReadFile(s.mutedFile()); err == nil && json.Unmarshal(raw, &ids) == nil {
		for _, id := range ids {
			s.muted[id] = true
		}
	}
}

// mutedIDs lists the muted IDs, sorted; call with s.mu held.
func (s *server) mutedIDs() []string {
	ids := []string{}
	for id := range s.muted {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// isMuted says whether a pane, or its session, is muted; call with s.mu held.
func (s *server) isMuted(p *pane) bool { return s.muted[p.block] || s.muted[p.session] }

func (s *server) loadDevices() {
	s.devices = map[string]*device{}
	if raw, err := os.ReadFile(s.devicesFile()); err == nil {
		var list []*device
		if json.Unmarshal(raw, &list) == nil {
			for _, d := range list {
				s.devices[d.Token] = d
			}
		}
	}
}

// saveDevices writes the device list; call with s.mu held.
func (s *server) saveDevices() {
	list := make([]*device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	raw, _ := json.MarshalIndent(list, "", "  ")
	_ = os.MkdirAll(s.cfg.state, 0o700)
	tmp := s.devicesFile() + ".tmp"
	if os.WriteFile(tmp, raw, 0o600) == nil {
		_ = os.Rename(tmp, s.devicesFile())
	}
}

// rexJSON runs a rex command against host ("" is this machine) and decodes its JSON.
func rexJSON(host string, out any, args ...string) error {
	if host != "" {
		args = append([]string{"-S", host}, args...)
	}
	raw, err := exec.Command("rex", args...).Output()
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, out)
}

func (s *server) title(host, session, block string) string {
	var r struct {
		Title string `json:"title"`
	}
	target := fmt.Sprintf(`{"session_id":%q,"block_id":%q,"args":{}}`, session, block)
	_ = rexJSON(host, &r, "api", "call", "com.superlogical.terminal.title", target)
	return r.Title
}

// scan reads what every pane reports now, so a restart doesn't forget agents mid-task.
func (s *server) scan(host string) {
	var list struct {
		Sessions []struct {
			ID string `json:"session_id"`
		} `json:"sessions"`
	}
	if rexJSON(host, &list, "api", "call", "session.list") != nil {
		return
	}
	for _, sess := range list.Sessions {
		var view struct {
			Windows []struct {
				Layers []struct {
					Blocks []struct {
						ID    string `json:"block_id"`
						Label string `json:"label"`
					} `json:"blocks"`
				} `json:"layers"`
			} `json:"windows"`
		}
		if rexJSON(host, &view, "api", "call", "session.view", fmt.Sprintf(`{"session_id":%q}`, sess.ID)) != nil {
			continue
		}
		for _, w := range view.Windows {
			for _, l := range w.Layers {
				for _, b := range l.Blocks {
					var st struct {
						Records []struct {
							State string `json:"state"`
							Msg   string `json:"msg"`
						} `json:"records"`
					}
					target := fmt.Sprintf(`{"session_id":%q,"block_id":%q,"args":{}}`, sess.ID, b.ID)
					if rexJSON(host, &st, "api", "call", "com.superlogical.terminal.program_status", target) != nil || len(st.Records) == 0 {
						continue
					}
					t := s.title(host, sess.ID, b.ID)
					if t == "" {
						t = b.Label
					}
					s.mu.Lock()
					s.panes[b.ID] = &pane{host: host, session: sess.ID, block: b.ID, title: t,
						state: st.Records[0].State, msg: st.Records[0].Msg, changed: time.Now()}
					s.mu.Unlock()
				}
			}
		}
	}
	s.changed()
}

// follow reads one host's events for as long as irex-push runs, reconnecting when they stop.
func (s *server) follow(host string) {
	for {
		s.scan(host)
		args := []string{"events", "--all", "--json"}
		if host != "" {
			args = append([]string{"-S", host}, args...)
		}
		cmd := exec.Command("rex", args...)
		out, err := cmd.StdoutPipe()
		if err == nil && cmd.Start() == nil {
			sc := bufio.NewScanner(out)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			for sc.Scan() {
				s.event(host, sc.Bytes())
			}
			_ = cmd.Wait()
		}
		log.Printf("events from %q stopped; again in 10s", host)
		time.Sleep(10 * time.Second)
	}
}

func (s *server) event(host string, line []byte) {
	var e struct {
		Type    string `json:"type"`
		Payload struct {
			Session string `json:"session_id"`
			Event   struct {
				Type    string `json:"type"`
				Payload struct {
					Block   string `json:"block_id"`
					Name    string `json:"name"`
					Payload struct {
						Title  string `json:"title"`
						Record struct {
							State string `json:"state"`
							Msg   string `json:"msg"`
						} `json:"record"`
					} `json:"payload"`
				} `json:"payload"`
			} `json:"event"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &e) != nil {
		return
	}
	if e.Type == "session_destroyed" {
		s.mu.Lock()
		for id, p := range s.panes {
			if p.session == e.Payload.Session {
				delete(s.panes, id)
			}
		}
		s.mu.Unlock()
		s.changed()
		return
	}
	if e.Type != "session_event" || e.Payload.Event.Type != "block_event" {
		return
	}
	b := e.Payload.Event.Payload
	switch b.Name {
	case "title_changed":
		s.mu.Lock()
		if p := s.panes[b.Block]; p != nil {
			p.title = b.Payload.Title
		}
		s.mu.Unlock()
	case "program_status_changed", "program_status_removed":
		state, msg := b.Payload.Record.State, b.Payload.Record.Msg
		if b.Name == "program_status_removed" {
			state = ""
		}
		s.mu.Lock()
		p := s.panes[b.Block]
		if p == nil {
			p = &pane{host: host, session: e.Payload.Session, block: b.Block}
			s.panes[b.Block] = p
		}
		was := p.state
		p.state, p.msg, p.changed = state, msg, time.Now()
		needTitle := p.title == ""
		s.mu.Unlock()
		if needTitle {
			t := s.title(host, e.Payload.Session, b.Block)
			s.mu.Lock()
			p.title = t
			s.mu.Unlock()
		}
		if state != was {
			s.alert(p, was)
		}
		s.changed()
	}
}

// alert notifies when an agent starts waiting on you, or finishes what it was doing.
func (s *server) alert(p *pane, was string) {
	s.mu.Lock()
	title, msg, state, quiet := p.title, p.msg, p.state, s.isMuted(p)
	s.mu.Unlock()
	if quiet {
		return
	}
	if title == "" {
		title = "A pane"
	}
	var heading, level string
	switch {
	case state == "blocked":
		heading, level = "Needs you", "time-sensitive"
	case state == "done" && was == "working":
		heading, level = "Done", "active"
	default:
		return
	}
	body := title
	if msg != "" {
		body = title + ": " + msg
	}
	payload := map[string]any{
		"aps": map[string]any{
			"alert":              map[string]string{"title": heading, "body": body},
			"sound":              "default",
			"thread-id":          p.block,
			"interruption-level": level,
		},
		"block": p.block,
	}
	s.each(func(d *device) error { return s.push.send(d.Env, d.Token, "alert", 10, payload) })
}

// each runs f for every device, dropping the ones Apple says are gone.
func (s *server) each(f func(*device) error) {
	s.mu.Lock()
	list := make([]*device, 0, len(s.devices))
	for _, d := range s.devices {
		list = append(list, d)
	}
	s.mu.Unlock()
	for _, d := range list {
		if err := f(d); errors.Is(err, errGone) {
			s.mu.Lock()
			delete(s.devices, d.Token)
			s.saveDevices()
			s.mu.Unlock()
			log.Printf("dropped device %.8s…", d.Token)
		} else if err != nil {
			log.Printf("push to %.8s…: %v", d.Token, err)
		}
	}
}

func (s *server) changed() {
	select {
	case s.dirty <- struct{}{}:
	default:
	}
}

// summary is what the Live Activity shows: counts, and the panes that matter most.
func (s *server) summary() contentState {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := contentState{Items: []item{}} // never null: the app decodes an array
	var rows []*pane
	for _, p := range s.panes {
		if s.isMuted(p) {
			continue
		}
		switch p.state {
		case "working":
			c.Working++
		case "blocked":
			c.Blocked++
		case "done":
			// Only recent finishes; older ones are history, not news.
			if time.Since(p.changed) > 30*time.Minute {
				continue
			}
			c.Done++
		default:
			continue
		}
		rows = append(rows, p)
	}
	rank := map[string]int{"blocked": 0, "working": 1, "done": 2}
	sort.Slice(rows, func(i, j int) bool {
		if rank[rows[i].state] != rank[rows[j].state] {
			return rank[rows[i].state] < rank[rows[j].state]
		}
		return rows[i].changed.After(rows[j].changed)
	})
	for i, p := range rows {
		if i == 3 {
			break
		}
		t := p.title
		if t == "" {
			t = "A pane"
		}
		c.Items = append(c.Items, item{Title: clip(t, 60), State: p.state, Detail: clip(p.msg, 80), Block: p.block})
	}
	return c
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// activities keeps the Live Activity in step: started by push when an agent gets going,
// updated as things change (at most every few seconds), and ended once all is quiet.
func (s *server) activities() {
	tick := time.NewTicker(time.Minute)
	for {
		select {
		case <-s.dirty:
		case <-tick.C:
		}
		time.Sleep(3 * time.Second) // let a burst of changes land as one update
		for len(s.dirty) > 0 {
			<-s.dirty
		}
		c := s.summary()
		busy := c.Working+c.Blocked > 0
		if busy {
			s.lastActive = time.Now()
		}
		urgent := c.Blocked > s.shown.Blocked
		switch {
		case busy && !s.active:
			s.active, s.shown = true, c
			s.liveActivity("start", c, urgent)
		case s.active && !busy && time.Since(s.lastActive) > 10*time.Minute:
			s.active = false
			s.liveActivity("end", c, urgent)
		case s.active && !equal(c, s.shown):
			s.shown = c
			s.liveActivity("update", c, urgent)
		}
	}
}

func equal(a, b contentState) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

func (s *server) liveActivity(event string, c contentState, urgent bool) {
	priority := 5
	if urgent || event != "update" {
		priority = 10
	}
	payload := func(event string) map[string]any {
		now := time.Now().Unix()
		aps := map[string]any{"timestamp": now, "event": event, "content-state": c}
		switch event {
		case "start":
			aps["attributes-type"] = "AgentsAttributes"
			aps["attributes"] = map[string]any{}
			aps["alert"] = map[string]string{"title": "Agents at work", "body": headline(c)}
		case "end":
			aps["dismissal-date"] = now + 15*60
		}
		return map[string]any{"aps": aps}
	}
	s.each(func(d *device) error {
		s.mu.Lock()
		start, act := d.StartToken, d.ActivityToken
		s.mu.Unlock()
		token, ev := act, event
		if event == "start" || (act == "" && event == "update") {
			// No activity of ours on this device yet: start one, but only one. Its own token
			// comes back from the app a moment later; until then, don't start another.
			s.mu.Lock()
			recent := time.Since(d.started) < 2*time.Minute
			if !recent {
				d.started = time.Now()
			}
			s.mu.Unlock()
			if recent && event != "start" {
				return nil
			}
			token, ev = start, "start"
		}
		if token == "" {
			return nil
		}
		err := s.push.send(d.Env, token, "liveactivity", priority, payload(ev))
		if ev == "end" || (errors.Is(err, errGone) && token == act) {
			s.mu.Lock()
			d.ActivityToken = ""
			s.saveDevices()
			s.mu.Unlock()
		}
		if errors.Is(err, errGone) {
			return nil // the activity is gone, not the device
		}
		return err
	})
}

func headline(c contentState) string {
	var parts []string
	if c.Blocked > 0 {
		parts = append(parts, fmt.Sprintf("%d need%s you", c.Blocked, map[bool]string{true: "s"}[c.Blocked == 1]))
	}
	if c.Working > 0 {
		parts = append(parts, fmt.Sprintf("%d working", c.Working))
	}
	return strings.Join(parts, " · ")
}

// ---- HTTP

func (s *server) register(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var in device
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&in); err != nil || !hexToken(in.Token) ||
		(in.Env != "sandbox" && in.Env != "production") ||
		(in.StartToken != "" && !hexToken(in.StartToken)) || (in.ActivityToken != "" && !hexToken(in.ActivityToken)) {
		http.Error(w, "bad registration", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	d := s.devices[in.Token]
	if d == nil {
		d = &device{Token: in.Token}
		s.devices[in.Token] = d
	}
	d.Env, d.Updated = in.Env, time.Now()
	if in.StartToken != "" {
		d.StartToken = in.StartToken
	}
	if in.ActivityToken != "" {
		d.ActivityToken = in.ActivityToken
	}
	s.saveDevices()
	s.mu.Unlock()
	log.Printf("registered %.8s… (%s)", in.Token, in.Env)
	s.changed()
	w.WriteHeader(http.StatusNoContent)
}

func hexToken(t string) bool {
	if len(t) < 32 || len(t) > 512 {
		return false
	}
	_, ok := new(big.Int).SetString(t, 16)
	return ok
}

// mutes lists the muted IDs (GET) or mutes or unmutes one (POST {"id", "muted"}).
func (s *server) mutes(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		var in struct {
			ID    string `json:"id"`
			Muted bool   `json:"muted"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&in); err != nil || len(in.ID) > 100 ||
			!(strings.HasPrefix(in.ID, "session:") || strings.HasPrefix(in.ID, "block:")) {
			http.Error(w, "bad mute", http.StatusBadRequest)
			return
		}
		s.mu.Lock()
		if in.Muted {
			s.muted[in.ID] = true
		} else {
			delete(s.muted, in.ID)
		}
		raw, _ := json.Marshal(s.mutedIDs())
		_ = os.MkdirAll(s.cfg.state, 0o700)
		_ = os.WriteFile(s.mutedFile(), raw, 0o600)
		s.mu.Unlock()
		s.changed()
	} else if r.Method != http.MethodGet {
		http.Error(w, "GET or POST", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	ids := s.mutedIDs()
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string][]string{"muted": ids})
}

// test sends every device a notification, to check the whole path.
func (s *server) test(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	payload := map[string]any{"aps": map[string]any{
		"alert": map[string]string{"title": "irex", "body": "Notifications from irex-push work."}, "sound": "default"}}
	s.each(func(d *device) error { return s.push.send(d.Env, d.Token, "alert", 10, payload) })
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	cfg := loadConfig()
	push, err := newAPNs(cfg)
	if err != nil {
		// Still take registrations, so devices are known once the key arrives.
		log.Printf("no APNs key (%v): taking registrations, sending nothing", err)
		push = &apns{cfg: cfg, client: &http.Client{Timeout: 15 * time.Second}}
	}
	s := &server{cfg: cfg, push: push, panes: map[string]*pane{}, dirty: make(chan struct{}, 1)}
	s.loadDevices()
	s.loadMuted()

	var hosts struct {
		Hosts []struct {
			Label string `json:"label"`
		} `json:"hosts"`
	}
	_ = rexJSON("", &hosts, "api", "call", "hosts.list")
	go s.follow("")
	for _, h := range hosts.Hosts {
		go s.follow(h.Label)
	}
	go s.activities()

	http.HandleFunc("/register", s.register)
	http.HandleFunc("/test", s.test)
	http.HandleFunc("/mutes", s.mutes)
	log.Printf("listening on %s for %d device(s), watching %d host(s)", cfg.listen, len(s.devices), 1+len(hosts.Hosts))
	log.Fatal(http.ListenAndServe(cfg.listen, nil))
}
