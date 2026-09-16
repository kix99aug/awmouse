package app

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Device is a phone the host has admitted once and will admit again without
// a code. ID is the phone's tailcat address: derived from its node key and
// bound to that key by WireGuard, so it names the device rather than the
// route it took.
type Device struct {
	ID    string    `json:"id"`
	Name  string    `json:"name"`
	Since time.Time `json:"since"`
}

const (
	// codeTTL bounds how long a QR code that has been photographed stays
	// useful. Every successful pairing also rotates the code immediately.
	codeTTL = 60 * time.Second

	// codeGrace keeps the previous code valid briefly after rotation. A phone
	// scans, then spends a few seconds bootstrapping the tunnel; landing on
	// the wrong side of a rotation in that gap must not send the user back
	// to the QR.
	codeGrace = 15 * time.Second

	// After this many wrong codes in a row, hellos are refused for lockFor.
	// With a six-digit code and a redial per attempt this already makes
	// guessing impractical; the lock makes it pointless.
	lockAfter = 5
	lockFor   = 30 * time.Second
)

// pairing owns the current code and the paired-device list. The list is
// persisted beside the host identity, since the two are only meaningful
// together: rotating the identity changes the address every phone has, which
// un-pairs them all regardless.
type pairing struct {
	mu sync.Mutex

	code   string
	issued time.Time

	// The code before this one, honoured until previousUntil.
	previous      string
	previousUntil time.Time

	devices map[string]Device
	path    string

	failures    int
	lockedUntil time.Time
}

func newPairing(path string) (*pairing, error) {
	p := &pairing{devices: map[string]Device{}, path: path}
	if err := p.load(); err != nil {
		return nil, err
	}
	p.rotateLocked(false)
	return p, nil
}

// Code returns the current pairing code, rotating it first if it has
// expired — so the value shown is always the value that will be accepted.
func (p *pairing) Code() (code string, expires time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Since(p.issued) > codeTTL {
		p.rotateLocked(true)
	}
	return p.code, p.issued.Add(codeTTL)
}

// rotateLocked replaces the code. The old one stays valid for codeGrace when
// it expired naturally — a scan in flight may still carry it — but not when
// it was just spent on an admission: a used code is done.
func (p *pairing) rotateLocked(graceful bool) {
	if graceful && p.code != "" {
		p.previous, p.previousUntil = p.code, time.Now().Add(codeGrace)
	} else {
		p.previous, p.previousUntil = "", time.Time{}
	}
	// Six digits, uniform. crypto/rand rather than math/rand: this is the
	// credential.
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		panic(fmt.Sprintf("pairing: crypto/rand failed: %v", err))
	}
	p.code = fmt.Sprintf("%06d", n.Int64())
	p.issued = time.Now()
}

func (p *pairing) acceptsLocked(code string) bool {
	if code == "" {
		return false
	}
	if code == p.code {
		return true
	}
	return code == p.previous && time.Now().Before(p.previousUntil)
}

func (p *pairing) IsPaired(id string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, ok := p.devices[id]
	return ok
}

// Try checks a code for an unpaired device. On success the device is
// recorded and the code rotated. The error, when there is one, is a reason
// the phone can act on.
func (p *pairing) Try(id, name, code string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if time.Now().Before(p.lockedUntil) {
		return errLocked
	}
	if time.Since(p.issued) > codeTTL {
		p.rotateLocked(true)
	}
	if !p.acceptsLocked(code) {
		p.failures++
		if p.failures >= lockAfter {
			p.failures = 0
			p.lockedUntil = time.Now().Add(lockFor)
		}
		return errBadCode
	}

	p.failures = 0
	if name == "" {
		name = "Phone"
	}
	p.devices[id] = Device{ID: id, Name: name, Since: time.Now()}
	p.rotateLocked(false)
	return p.saveLocked()
}

func (p *pairing) Forget(id string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.devices, id)
	return p.saveLocked()
}

func (p *pairing) Devices() []Device {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]Device, 0, len(p.devices))
	for _, d := range p.devices {
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Since.Before(out[j].Since) })
	return out
}

var (
	errBadCode = errors.New("wrong or missing pairing code")
	errLocked  = errors.New("too many wrong codes; try again in a moment")
)

// MARK: - persistence

func (p *pairing) load() error {
	b, err := os.ReadFile(p.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var list []Device
	if err := json.Unmarshal(b, &list); err != nil {
		return fmt.Errorf("paired devices file: %w", err)
	}
	for _, d := range list {
		p.devices[d.ID] = d
	}
	return nil
}

func (p *pairing) saveLocked() error {
	list := make([]Device, 0, len(p.devices))
	for _, d := range p.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Since.Before(list[j].Since) })

	b, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.path), 0o700); err != nil {
		return err
	}
	// Write-then-rename, so a crash mid-write cannot leave a truncated list
	// that admits nobody.
	tmp := p.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p.path)
}

// DefaultPairedPath is the device list's location: next to the identity.
func DefaultPairedPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "awmouse", "paired-devices.json"), nil
}
