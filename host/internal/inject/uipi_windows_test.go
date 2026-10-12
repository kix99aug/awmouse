//go:build windows

package inject

import (
	"bytes"
	"log"
	"strings"
	"testing"
	"time"
)

// TestOwnIntegrityIsPlausible pins the one number the comparison rests on.
// Unelevated is medium; elevating the test run makes it high.
func TestOwnIntegrityIsPlausible(t *testing.T) {
	lvl, err := ownIntegrity()
	if err != nil {
		t.Fatalf("ownIntegrity: %v", err)
	}
	if lvl < 0x1000 || lvl > 0x4000 {
		t.Errorf("own integrity %#x is outside the defined range", lvl)
	}
	if Elevated() != (lvl >= 0x3000) {
		t.Errorf("Elevated() = %v but integrity is %#x", Elevated(), lvl)
	}
	t.Logf("own integrity %#x, elevated %v", lvl, Elevated())
}

// TestForegroundComparison exercises the real syscall path — opening another
// process, reading its token, naming it — against whatever window happens to
// be focused, and checks the comparison in both directions.
func TestForegroundComparison(t *testing.T) {
	if _, blocked := foregroundOutranksUs(0xFFFF); blocked {
		t.Error("nothing should outrank the highest possible level")
	}

	name, blocked := foregroundOutranksUs(0)
	if name == "" {
		t.Skip("no foreground window: a service or a locked desktop")
	}
	if !blocked {
		t.Errorf("foreground %q should outrank level 0", name)
	}

	_, realBlocked := foregroundOutranksUs(mustOwn(t))
	t.Logf("foreground is %q; blocks us: %v", name, realBlocked)
}

func mustOwn(t *testing.T) uint32 {
	t.Helper()
	lvl, err := ownIntegrity()
	if err != nil {
		t.Fatalf("ownIntegrity: %v", err)
	}
	return lvl
}

// TestWarningFiresOncePerTransition is the behaviour that matters: the user
// must be told the first time their input starts vanishing, and must not have
// the log buried under one line per injected event afterwards.
func TestWarningFiresOncePerTransition(t *testing.T) {
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(nil) })

	// Pretend to be the least privileged process on the machine, so the real
	// foreground window outranks us.
	reset := func(own uint32) {
		uipi.Lock()
		defer uipi.Unlock()
		uipi.own, uipi.ownKnown = own, true
		uipi.lastCheck = time.Time{}
		uipi.blocked = false
	}

	reset(0)
	warnIfForegroundBlocksInput()
	first := buf.String()
	if !strings.Contains(first, "input is being dropped") {
		t.Fatalf("no warning logged; got %q", first)
	}
	if !strings.Contains(first, "administrator") {
		t.Errorf("warning does not say what to do about it: %q", first)
	}

	// A second call inside the rate-limit window must say nothing, and so must
	// one after it, since the verdict has not changed.
	buf.Reset()
	warnIfForegroundBlocksInput()
	uipi.Lock()
	uipi.lastCheck = time.Time{}
	uipi.Unlock()
	warnIfForegroundBlocksInput()
	if buf.Len() != 0 {
		t.Errorf("warning repeated while the verdict was unchanged: %q", buf.String())
	}

	// Becoming reachable again is also worth one line.
	buf.Reset()
	uipi.Lock()
	uipi.own = 0xFFFF
	uipi.lastCheck = time.Time{}
	uipi.Unlock()
	warnIfForegroundBlocksInput()
	if !strings.Contains(buf.String(), "accepts injected input again") {
		t.Errorf("recovery not logged; got %q", buf.String())
	}
}
