package tunnel

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestAuthMethodsMissingIdentity(t *testing.T) {
	if _, err := authMethods(filepath.Join(t.TempDir(), "does-not-exist")); err == nil {
		t.Fatal("expected error for a missing identity file")
	}
}

func TestAuthMethodsWithIdentity(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(priv, "")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "id_ed25519")
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	methods, err := authMethods(path)
	if err != nil {
		t.Fatalf("authMethods: %v", err)
	}
	if len(methods) == 0 {
		t.Fatal("expected a public-key auth method from the identity file")
	}
}

func TestClientConfigNoAuth(t *testing.T) {
	t.Setenv("SSH_AUTH_SOCK", "") // ensure no agent is picked up
	kh := writeEmptyKnownHosts(t)
	if _, err := clientConfig(Config{User: "me", KnownHostsFile: kh}); err == nil {
		t.Fatal("expected error when no auth methods are available")
	}
}

func TestHostKeyCallbackRequiresFile(t *testing.T) {
	if _, err := hostKeyCallback(""); err == nil {
		t.Fatal("expected error when knownHostsFile is empty")
	}
}

// TestServeStopsOnContextCancel verifies the supervisor loop honors context
// cancellation instead of retrying forever. With no reachable dev box the first
// attempt fails fast; cancelling during the backoff must make Serve return.
func TestServeStopsOnContextCancel(t *testing.T) {
	t.Setenv("SSH_AUTH_SOCK", "")
	cfg := Config{
		Host:           "127.0.0.1",
		Port:           1, // nothing listens here; connect fails fast
		User:           "nobody",
		KnownHostsFile: writeEmptyKnownHosts(t),
		RemoteBind:     "127.0.0.1",
		RemotePort:     39788,
		KeepAliveSec:   1,
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		Serve(ctx, cfg, http.NewServeMux())
		close(done)
	}()
	time.Sleep(150 * time.Millisecond) // let it attempt at least once
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return after context cancellation")
	}
}

func writeEmptyKnownHosts(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "known_hosts")
	if err := os.WriteFile(path, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
