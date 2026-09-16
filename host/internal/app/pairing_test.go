package app

import (
	"path/filepath"
	"testing"
	"time"
)

func newTestPairing(t *testing.T) *pairing {
	t.Helper()
	p, err := newPairing(filepath.Join(t.TempDir(), "paired.json"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCodeIsSixDigits(t *testing.T) {
	p := newTestPairing(t)
	code, _ := p.Code()
	if len(code) != 6 {
		t.Fatalf("code %q is not six characters", code)
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			t.Fatalf("code %q is not all digits", code)
		}
	}
}

// The code is the only thing standing between a photographed QR and the
// cursor, so the right code must admit and anything else must not.
func TestRightCodePairsAndWrongCodeDoesNot(t *testing.T) {
	p := newTestPairing(t)
	code, _ := p.Code()

	// Any code but this one; flipping a digit guarantees a mismatch.
	wrong := []byte(code)
	wrong[0] = '0' + (wrong[0]-'0'+1)%10

	if err := p.Try("phone-a", "iPhone", string(wrong)); err != errBadCode {
		t.Fatalf("wrong code: got %v, want errBadCode", err)
	}
	if p.IsPaired("phone-a") {
		t.Fatal("device recorded despite wrong code")
	}

	if err := p.Try("phone-a", "iPhone", code); err != nil {
		t.Fatalf("right code refused: %v", err)
	}
	if !p.IsPaired("phone-a") {
		t.Fatal("device not recorded after right code")
	}
}

// A code that has admitted one phone must not admit a second: the QR may
// still be on screen, or in someone's camera roll.
func TestSuccessfulPairingRotatesTheCode(t *testing.T) {
	p := newTestPairing(t)
	code, _ := p.Code()
	if err := p.Try("phone-a", "", code); err != nil {
		t.Fatal(err)
	}
	if err := p.Try("phone-b", "", code); err == nil {
		t.Fatal("spent code admitted a second device")
	}
	after, _ := p.Code()
	if after == code {
		t.Fatal("code did not rotate after pairing")
	}
}

func TestRepeatedWrongCodesLockOut(t *testing.T) {
	p := newTestPairing(t)
	code, _ := p.Code()

	for range lockAfter {
		_ = p.Try("attacker", "", "999999")
	}
	// Even the right code is refused while locked.
	if err := p.Try("attacker", "", code); err != errLocked {
		t.Fatalf("expected lockout, got %v", err)
	}
}

func TestPairedDevicesSurviveRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "paired.json")
	first, err := newPairing(path)
	if err != nil {
		t.Fatal(err)
	}
	code, _ := first.Code()
	if err := first.Try("phone-a", "iPhone", code); err != nil {
		t.Fatal(err)
	}

	second, err := newPairing(path)
	if err != nil {
		t.Fatal(err)
	}
	if !second.IsPaired("phone-a") {
		t.Fatal("pairing lost across restart")
	}
	devs := second.Devices()
	if len(devs) != 1 || devs[0].Name != "iPhone" {
		t.Fatalf("devices = %+v", devs)
	}
}

func TestForgetRevokes(t *testing.T) {
	p := newTestPairing(t)
	code, _ := p.Code()
	if err := p.Try("phone-a", "", code); err != nil {
		t.Fatal(err)
	}
	if err := p.Forget("phone-a"); err != nil {
		t.Fatal(err)
	}
	if p.IsPaired("phone-a") {
		t.Fatal("device still paired after Forget")
	}
}

func TestExpiredCodeIsReplacedWhenRead(t *testing.T) {
	p := newTestPairing(t)
	before, _ := p.Code()
	p.mu.Lock()
	p.issued = time.Now().Add(-codeTTL - time.Second)
	p.mu.Unlock()
	after, _ := p.Code()
	if before == after {
		t.Fatal("expired code was shown again")
	}
}

// A phone scans, then spends seconds bringing the tunnel up. If the code
// rotates in that gap the scan must still land — for a little while.
func TestCodeThatJustExpiredStillAdmitsBriefly(t *testing.T) {
	p := newTestPairing(t)
	scanned, _ := p.Code()

	p.mu.Lock()
	p.issued = time.Now().Add(-codeTTL - time.Second)
	p.mu.Unlock()
	_, _ = p.Code() // rotates; `scanned` is now the previous code

	if err := p.Try("phone-a", "", scanned); err != nil {
		t.Fatalf("code in flight across a rotation was refused: %v", err)
	}
}

func TestGraceIsShort(t *testing.T) {
	p := newTestPairing(t)
	scanned, _ := p.Code()

	p.mu.Lock()
	p.issued = time.Now().Add(-codeTTL - time.Second)
	p.mu.Unlock()
	_, _ = p.Code()
	p.mu.Lock()
	p.previousUntil = time.Now().Add(-time.Second) // grace elapsed
	p.mu.Unlock()

	if err := p.Try("phone-a", "", scanned); err == nil {
		t.Fatal("stale code admitted after the grace period")
	}
}

// Grace applies to natural expiry only. A code that admitted a phone is
// spent; the QR it came from may still be on someone's screen.
func TestSpentCodeGetsNoGrace(t *testing.T) {
	p := newTestPairing(t)
	code, _ := p.Code()
	if err := p.Try("phone-a", "", code); err != nil {
		t.Fatal(err)
	}
	if err := p.Try("phone-b", "", code); err == nil {
		t.Fatal("spent code admitted a second phone within what would be the grace window")
	}
}
