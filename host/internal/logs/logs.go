// Package logs sends the standard logger to a file as well as stderr.
//
// The host is a GUI app, and a GUI app's stderr goes nowhere: launched from
// Finder there is no terminal attached, and macOS discards it rather than
// routing it anywhere a user could find. Anything that goes wrong after the
// window is open — a tunnel that drops, a phone that stops answering — is
// therefore invisible unless it is written down.
package logs

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
)

// maxBytes caps the current log. At the limit it becomes the .1 file and a
// fresh one starts, so at most two of these exist and the disk cost is
// bounded however long the app runs.
const maxBytes = 2 << 20 // 2 MiB

// Setup points the standard logger at both stderr and a file, and returns the
// file's path. An unwritable location is not fatal: logging to stderr alone is
// worse than logging to both, and better than refusing to start.
func Setup() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	dir = filepath.Join(dir, "awmouse")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "awmouse.log")

	w := &rotating{path: path}
	if err := w.open(); err != nil {
		return "", err
	}

	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	log.SetOutput(io.MultiWriter(os.Stderr, w))
	return path, nil
}

// Path reports where Setup would write, without creating anything. For the
// window to show even when logging could not be set up.
func Path() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "awmouse", "awmouse.log")
}

type rotating struct {
	mu   sync.Mutex
	path string
	f    *os.File
	n    int64
}

func (r *rotating) open() error {
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	r.f, r.n = f, info.Size()
	return nil
}

func (r *rotating) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.f == nil {
		return len(p), nil // rotation failed earlier; stderr still has it
	}
	if r.n+int64(len(p)) > maxBytes {
		r.f.Close()
		// Replace rather than accumulate: two files is all the history worth
		// keeping, and an unbounded pile in a config directory is litter.
		if err := os.Rename(r.path, r.path+".1"); err != nil {
			fmt.Fprintf(os.Stderr, "log rotate: %v\n", err)
		}
		if err := r.open(); err != nil {
			fmt.Fprintf(os.Stderr, "log reopen: %v\n", err)
			r.f = nil
			return len(p), nil
		}
	}
	n, err := r.f.Write(p)
	r.n += int64(n)
	return n, err
}
