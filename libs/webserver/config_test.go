package webserver

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateRequiresToken(t *testing.T) {
	c := Default()
	if err := c.Validate(); err == nil {
		t.Fatal("expected error when token is empty")
	}
}

func TestValidateLocalRejectsNonLoopback(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.Bind = "0.0.0.0"
	if err := c.Validate(); err == nil {
		t.Fatal("expected local mode to reject a non-loopback bind")
	}
}

func TestValidateNetworkRequiresTLS(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.Mode = ModeNetwork
	c.Bind = "0.0.0.0"
	if err := c.Validate(); err == nil {
		t.Fatal("expected network mode to require TLS")
	}
	c.TLS = TLSConfig{Cert: "/tmp/c.pem", Key: "/tmp/k.pem"}
	if err := c.Validate(); err != nil {
		t.Fatalf("network mode with TLS should validate: %v", err)
	}
}

func TestValidateUnknownIDE(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.IDE = "emacs"
	if err := c.Validate(); err == nil {
		t.Fatal("expected error for IDE with no profile")
	}
}

func TestIsLoopback(t *testing.T) {
	cases := map[string]bool{
		"":          true,
		"localhost": true,
		"127.0.0.1": true,
		"127.0.1.5": true,
		"::1":       true,
		"0.0.0.0":   false,
		"10.0.0.5":  false,
	}
	for bind, want := range cases {
		if got := isLoopback(bind); got != want {
			t.Errorf("isLoopback(%q) = %v, want %v", bind, got, want)
		}
	}
}

func TestUnmarshalJSONC(t *testing.T) {
	data := []byte(`{
		// line comment
		"mode": "local",
		"port": 39788, /* block */
		"ide": "cursor",
		"profiles": {
			"cursor": {
				"process": "Cursor",
				"remoteUri": "vscode-remote://ssh-remote+{host}{path}", // keep the // in the URI
			},
		},
	}`)
	var c Config
	if err := unmarshalJSONC(data, &c); err != nil {
		t.Fatalf("unmarshalJSONC: %v", err)
	}
	if c.Mode != ModeLocal || c.Port != 39788 {
		t.Fatalf("unexpected parse: %+v", c)
	}
	if got := c.Profiles["cursor"].RemoteURI; got != "vscode-remote://ssh-remote+{host}{path}" {
		t.Fatalf("URI mangled by comment stripper: %q", got)
	}
}

func TestActiveProfile(t *testing.T) {
	c := Default()
	p, ok := c.ActiveProfile()
	if !ok || p.Process != "Cursor" {
		t.Fatalf("active profile = %+v ok=%v", p, ok)
	}
}

func TestValidateTunnelRequiresHost(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.Tunnel = &TunnelConfig{Enabled: true}
	if err := c.Validate(); err == nil {
		t.Fatal("expected error when tunnel.enabled but host is empty")
	}
	c.Tunnel.Host = "devbox"
	if err := c.Validate(); err != nil {
		t.Fatalf("tunnel with host should validate: %v", err)
	}
}

func TestValidateTunnelDisabledIgnoresHost(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.Tunnel = &TunnelConfig{Enabled: false}
	if err := c.Validate(); err != nil {
		t.Fatalf("a disabled tunnel should not require host: %v", err)
	}
}

func TestApplyTunnelDefaults(t *testing.T) {
	c := Default()
	c.Port = 39788
	c.Tunnel = &TunnelConfig{Enabled: true, Host: "devbox"}
	c.applyTunnelDefaults()
	tn := c.Tunnel
	if tn.Port != 22 {
		t.Errorf("ssh port default = %d, want 22", tn.Port)
	}
	if tn.RemoteBind != "127.0.0.1" {
		t.Errorf("remoteBind default = %q, want 127.0.0.1", tn.RemoteBind)
	}
	if tn.RemotePort != 39788 {
		t.Errorf("remotePort default = %d, want 39788 (cfg.Port)", tn.RemotePort)
	}
	if tn.KeepAliveSec != 30 {
		t.Errorf("keepAliveSec default = %d, want 30", tn.KeepAliveSec)
	}
	if tn.User == "" {
		t.Error("user default should be non-empty")
	}
}

func TestApplyTunnelDefaultsNoBlock(t *testing.T) {
	c := Default()
	c.applyTunnelDefaults() // must not panic when Tunnel is nil
	if c.Tunnel != nil {
		t.Fatal("applyTunnelDefaults should not materialize a tunnel block")
	}
}

func TestExpandUser(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir on this platform")
	}
	if got, want := expandUser("~/.ssh/id_ed25519"), filepath.Join(home, ".ssh", "id_ed25519"); got != want {
		t.Errorf("expandUser(~/...) = %q, want %q", got, want)
	}
	if got := expandUser("/abs/path"); got != "/abs/path" {
		t.Errorf("absolute path should be unchanged, got %q", got)
	}
	if got := expandUser(""); got != "" {
		t.Errorf("empty should stay empty, got %q", got)
	}
}

func TestUnmarshalJSONCTunnel(t *testing.T) {
	data := []byte(`{
		"mode": "ssh",
		"tunnel": {
			"enabled": true,
			"host": "dev-box.example.com",
			"user": "me",
			"identityFile": "~/.ssh/id_ed25519",
		},
	}`)
	var c Config
	if err := unmarshalJSONC(data, &c); err != nil {
		t.Fatalf("unmarshalJSONC: %v", err)
	}
	if c.Tunnel == nil || !c.Tunnel.Enabled || c.Tunnel.Host != "dev-box.example.com" {
		t.Fatalf("tunnel not parsed: %+v", c.Tunnel)
	}
}
