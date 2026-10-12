//go:build windows

package inject

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows refuses injected input aimed at a window whose process runs at a
// higher integrity level than ours — User Interface Privilege Isolation. It
// is silent about it: SendInput reports one event inserted and sets no error,
// the cursor simply does not move. So the only way to explain the symptom is
// to go and look at the foreground window.
//
// Comparing integrity levels is exact, unlike watching whether the cursor
// moved: a physical mouse in the user's other hand would make that guess
// wrong.
var (
	procGetForegroundWindow      = user32.NewProc("GetForegroundWindow")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
)

// checkEvery bounds the cost: three syscalls twice a second against a move
// stream arriving at 60 Hz.
const checkEvery = 500 * time.Millisecond

var uipi struct {
	sync.Mutex
	own       uint32 // this process's integrity level, read once
	ownKnown  bool
	lastCheck time.Time
	blocked   bool // the verdict as of lastCheck, for transition logging
}

// warnIfForegroundBlocksInput logs once each time the foreground window starts
// or stops outranking this process. Called from the injection path rather than
// a goroutine, so it costs nothing while no one is driving the cursor.
func warnIfForegroundBlocksInput() {
	uipi.Lock()
	defer uipi.Unlock()

	now := time.Now()
	if now.Sub(uipi.lastCheck) < checkEvery {
		return
	}
	uipi.lastCheck = now

	if !uipi.ownKnown {
		lvl, err := ownIntegrity()
		if err != nil {
			return // cannot compare; say nothing rather than guess
		}
		uipi.own, uipi.ownKnown = lvl, true
	}

	name, blocked := foregroundOutranksUs(uipi.own)
	if blocked == uipi.blocked {
		return
	}
	uipi.blocked = blocked
	if blocked {
		log.Printf("input is being dropped: the foreground window (%s) runs at a "+
			"higher integrity level than this process. Windows blocks injected "+
			"input into elevated windows; run awmoused as administrator to reach "+
			"them.", name)
	} else {
		log.Printf("foreground window (%s) accepts injected input again", name)
	}
}

// foregroundOutranksUs reports the foreground process's name and whether its
// integrity level is above own. A process whose token cannot be read at all
// is treated as outranking us: for a window in the user's own session that is
// what being unable to open it means.
func foregroundOutranksUs(own uint32) (name string, outranks bool) {
	hwnd, _, _ := procGetForegroundWindow.Call()
	if hwnd == 0 {
		return "", false // nothing focused, e.g. the secure desktop
	}
	var pid uint32
	procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	if pid == 0 {
		return "", false
	}

	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return fmt.Sprintf("pid %d", pid), true
	}
	defer windows.CloseHandle(h)

	name = processName(h, pid)
	lvl, err := tokenIntegrity(h)
	if err != nil {
		return name, true
	}
	return name, lvl > own
}

func processName(h windows.Handle, pid uint32) string {
	buf := make([]uint16, windows.MAX_PATH)
	n := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &n); err != nil {
		return fmt.Sprintf("pid %d", pid)
	}
	path := windows.UTF16ToString(buf[:n])
	if i := strings.LastIndexAny(path, `\/`); i >= 0 {
		return path[i+1:]
	}
	return path
}

func ownIntegrity() (uint32, error) {
	var tok windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &tok); err != nil {
		return 0, err
	}
	defer tok.Close()
	return integrityOfToken(tok)
}

func tokenIntegrity(h windows.Handle) (uint32, error) {
	var tok windows.Token
	if err := windows.OpenProcessToken(h, windows.TOKEN_QUERY, &tok); err != nil {
		return 0, err
	}
	defer tok.Close()
	return integrityOfToken(tok)
}

// integrityOfToken returns the RID of the token's mandatory label: 0x1000 low,
// 0x2000 medium, 0x3000 high (what elevation gets you), 0x4000 system.
func integrityOfToken(tok windows.Token) (uint32, error) {
	var n uint32
	// The first call fails with ERROR_INSUFFICIENT_BUFFER and sets the size.
	windows.GetTokenInformation(tok, windows.TokenIntegrityLevel, nil, 0, &n)
	if n == 0 {
		return 0, fmt.Errorf("integrity label size is zero")
	}
	buf := make([]byte, n)
	if err := windows.GetTokenInformation(tok, windows.TokenIntegrityLevel, &buf[0], n, &n); err != nil {
		return 0, err
	}
	label := (*windows.Tokenmandatorylabel)(unsafe.Pointer(&buf[0]))
	sid := label.Label.Sid
	return sid.SubAuthority(uint32(sid.SubAuthorityCount()) - 1), nil
}

// Elevated reports whether this process holds an elevated token, for the
// startup banner.
func Elevated() bool {
	var tok windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &tok); err != nil {
		return false
	}
	defer tok.Close()
	return tok.IsElevated()
}
