package transport

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
)

// Identity is the host's tailcat identity. Both halves go into the address the
// phone scans, so both must survive restarts or the QR would have to be
// rescanned every launch — the failure DESIGN.md's pairing section rules out.
type Identity struct {
	Key key.NodePrivate      `json:"key"`
	PSK tailcat.PresharedKey `json:"psk"`
}

// DefaultIdentityPath is where the host keeps its identity when no path is
// given: the platform's per-user config directory.
func DefaultIdentityPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "awmouse", "host-identity.json"), nil
}

// LoadOrCreateIdentity reads the identity at path, generating and saving a
// fresh one if there is none yet. The file holds a private key and the
// pre-shared key, so it is written owner-only.
func LoadOrCreateIdentity(path string) (Identity, error) {
	var id Identity
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(data, &id); err != nil {
			return Identity{}, fmt.Errorf("identity %s: %w", path, err)
		}
		if id.Key.IsZero() || id.PSK.IsZero() {
			return Identity{}, fmt.Errorf("identity %s: missing key material", path)
		}
		return id, nil
	case errors.Is(err, os.ErrNotExist):
		// fall through to create
	default:
		return Identity{}, err
	}

	id = Identity{Key: key.NewNode(), PSK: tailcat.NewPresharedKey()}
	data, err = json.MarshalIndent(id, "", "  ")
	if err != nil {
		return Identity{}, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return Identity{}, err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return Identity{}, err
	}
	return id, nil
}
