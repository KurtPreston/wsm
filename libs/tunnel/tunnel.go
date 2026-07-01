// Package tunnel maintains a reverse SSH tunnel from the workstation to a dev
// box and serves an HTTP handler on a listener bound to the dev box's loopback.
//
// It lets wsmd own the pipe that grove/docentd use to reach it, independent of
// any external SSH session (e.g. Cursor Remote-SSH). Because wsmd autostarts at
// login, a tunnel it owns is live exactly when it is needed. The reverse
// listener is served by the same http.Handler as the local loopback listener,
// so requests arriving over the tunnel are handled directly with no extra hop.
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
	"golang.org/x/crypto/ssh/knownhosts"
)

// Config describes how to dial the dev box and where the reverse listener binds
// on it. It mirrors the fields of webserver.TunnelConfig (the caller maps one
// to the other) but carries no JSON/config concerns so this package depends
// only on the standard library and golang.org/x/crypto.
type Config struct {
	Host           string
	Port           int
	User           string
	IdentityFile   string
	KnownHostsFile string
	RemoteBind     string
	RemotePort     int
	KeepAliveSec   int
}

// Serve maintains the reverse tunnel until ctx is cancelled, reconnecting with
// exponential backoff. Each successful connection serves handler over a reverse
// listener on the dev box. Serve blocks; run it in a goroutine. A failing or
// dropped tunnel never panics — it is logged and retried.
func Serve(ctx context.Context, cfg Config, handler http.Handler) {
	const (
		minBackoff = time.Second
		maxBackoff = 30 * time.Second
		stableFor  = 30 * time.Second
	)
	backoff := minBackoff
	for {
		if ctx.Err() != nil {
			return
		}
		start := time.Now()
		err := connectAndServe(ctx, cfg, handler)
		if ctx.Err() != nil {
			return
		}
		if time.Since(start) >= stableFor {
			backoff = minBackoff // was healthy for a while; treat as a fresh drop
		}
		if err != nil {
			log.Printf("wsm tunnel: %v; retrying in %s", err, backoff)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < maxBackoff {
			if backoff *= 2; backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}
}

// connectAndServe dials the dev box, opens the reverse listener, and serves the
// handler over it until the connection drops, ctx is cancelled, or a keepalive
// fails. It always returns with the SSH client and listener closed.
func connectAndServe(ctx context.Context, cfg Config, handler http.Handler) error {
	clientCfg, err := clientConfig(cfg)
	if err != nil {
		return err
	}
	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))
	client, err := ssh.Dial("tcp", addr, clientCfg)
	if err != nil {
		return fmt.Errorf("dial %s: %w", addr, err)
	}
	defer client.Close()

	remoteAddr := net.JoinHostPort(cfg.RemoteBind, strconv.Itoa(cfg.RemotePort))
	ln, err := client.Listen("tcp", remoteAddr)
	if err != nil {
		// A common, benign case: another SSH session (e.g. Cursor Remote-SSH)
		// already holds this reverse forward. We back off and retry; that
		// session's forward keeps reaching this same wsmd meanwhile.
		return fmt.Errorf("remote listen %s (already forwarded by another ssh session?): %w", remoteAddr, err)
	}
	defer ln.Close()

	log.Printf("wsm tunnel: up — %s@%s serving on remote %s", cfg.User, addr, remoteAddr)

	srv := &http.Server{Handler: handler}
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(ln) }()

	closed := make(chan struct{})
	go func() { _ = client.Wait(); close(closed) }()

	interval := time.Duration(cfg.KeepAliveSec) * time.Second
	if interval <= 0 {
		interval = 30 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			_ = srv.Close()
			return ctx.Err()
		case err := <-serveErr:
			return fmt.Errorf("serve stopped: %w", err)
		case <-closed:
			_ = srv.Close()
			return errors.New("ssh connection closed")
		case <-ticker.C:
			if _, _, err := client.SendRequest("keepalive@openssh.com", true, nil); err != nil {
				_ = srv.Close()
				return fmt.Errorf("keepalive failed: %w", err)
			}
		}
	}
}

// clientConfig assembles the SSH client config: auth methods plus strict host
// key verification against the known_hosts file.
func clientConfig(cfg Config) (*ssh.ClientConfig, error) {
	auths, err := authMethods(cfg.IdentityFile)
	if err != nil {
		return nil, err
	}
	if len(auths) == 0 {
		return nil, errors.New("no ssh auth available: set tunnel.identityFile or start an ssh-agent (SSH_AUTH_SOCK)")
	}
	hostKeys, err := hostKeyCallback(cfg.KnownHostsFile)
	if err != nil {
		return nil, err
	}
	return &ssh.ClientConfig{
		User:            cfg.User,
		Auth:            auths,
		HostKeyCallback: hostKeys,
		Timeout:         15 * time.Second,
	}, nil
}

// authMethods builds the SSH auth methods: an explicit identity file when set,
// and the ssh-agent when SSH_AUTH_SOCK points at a reachable agent. For a
// login-launched daemon an identityFile is the more reliable choice, since an
// interactive agent may not be present in the service's environment.
func authMethods(identityFile string) ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod
	if identityFile != "" {
		key, err := os.ReadFile(identityFile)
		if err != nil {
			return nil, fmt.Errorf("read identity %s: %w", identityFile, err)
		}
		signer, err := ssh.ParsePrivateKey(key)
		if err != nil {
			return nil, fmt.Errorf("parse identity %s (encrypted keys need an ssh-agent): %w", identityFile, err)
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if sock := os.Getenv("SSH_AUTH_SOCK"); sock != "" {
		// Unix-domain agent socket. On Windows the agent uses a named pipe and
		// this dial simply fails; the identityFile path covers that case.
		if conn, err := net.Dial("unix", sock); err == nil {
			methods = append(methods, ssh.PublicKeysCallback(agent.NewClient(conn).Signers))
		}
	}
	return methods, nil
}

// hostKeyCallback verifies the dev box against known_hosts. There is no
// insecure fallback: the dev box is already trusted there whenever Cursor has
// connected to it.
func hostKeyCallback(knownHostsFile string) (ssh.HostKeyCallback, error) {
	if knownHostsFile == "" {
		return nil, errors.New("knownHostsFile is required for host key verification")
	}
	cb, err := knownhosts.New(knownHostsFile)
	if err != nil {
		return nil, fmt.Errorf("known_hosts %s: %w", knownHostsFile, err)
	}
	return cb, nil
}
