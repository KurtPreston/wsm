// Package webserver is the shared HTTP layer for the wsm workspace-management
// daemon. It owns routing, Bearer auth, CORS, and mode (local/ssh/network)
// enforcement, and delegates the actual window operations to a platform
// WindowManager implementation.
package webserver

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"github.com/KurtPreston/wsm/libs/api"
	"github.com/KurtPreston/wsm/libs/tunnel"
)

// ErrWindowNotFound is returned by WindowManager.Focus when no open window
// matches the request; the server maps it to HTTP 404.
var ErrWindowNotFound = errors.New("no matching window")

// OpenCommand is a fully-resolved open request handed to a WindowManager: the
// name is defaulted and the folder URI is resolved from the active profile.
type OpenCommand struct {
	Host    string
	Path    string
	Name    string
	URI     string
	Profile IDEProfile
}

// FocusCommand is a focus request plus the active profile.
type FocusCommand struct {
	ID      string
	Name    string
	Host    string
	Profile IDEProfile
}

// WindowManager is the platform-specific behavior each app supplies.
type WindowManager interface {
	List(ctx context.Context, profile IDEProfile) ([]api.Window, error)
	Open(ctx context.Context, cmd OpenCommand) (api.Result, error)
	Focus(ctx context.Context, cmd FocusCommand) (api.Result, error)
}

type server struct {
	cfg Config
	wm  WindowManager
}

// NewHandler builds the HTTP handler for the given config and window manager.
// It validates the config and returns an error if the mode invariants fail.
func NewHandler(cfg Config, wm WindowManager) (http.Handler, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	s := &server{cfg: cfg, wm: wm}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", methodGuard(http.MethodGet, s.health))
	mux.HandleFunc("/windows", methodGuard(http.MethodGet, requireBearer(cfg.Token, cfg.CORSOrigin, s.windows)))
	mux.HandleFunc("/open", methodGuard(http.MethodPost, requireBearer(cfg.Token, cfg.CORSOrigin, s.open)))
	mux.HandleFunc("/focus", methodGuard(http.MethodPost, requireBearer(cfg.Token, cfg.CORSOrigin, s.focus)))

	return withCORS(cfg.CORSOrigin, mux), nil
}

// methodGuard enforces the HTTP method for a route. Method-in-pattern routing
// (e.g. "GET /windows") requires Go 1.22's ServeMux, but this module targets an
// older Go floor, so we register literal paths and validate the method here.
// Preflight OPTIONS requests are answered upstream by withCORS and never reach
// these handlers.
func methodGuard(method string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != method {
			w.Header().Set("Allow", method)
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		next(w, r)
	}
}

// Serve validates the config and serves until the process exits. It uses HTTPS
// in network mode and plain HTTP on loopback (local/ssh). When a tunnel is
// configured, the same handler is also served over a reverse SSH tunnel that
// wsmd owns (see libs/tunnel), so the dev box can reach it without relying on
// an external SSH session such as Cursor Remote-SSH.
func Serve(cfg Config, wm WindowManager) error {
	h, err := NewHandler(cfg, wm)
	if err != nil {
		return err
	}
	if cfg.Tunnel != nil && cfg.Tunnel.Enabled {
		tc := tunnel.Config{
			Host:           cfg.Tunnel.Host,
			Port:           cfg.Tunnel.Port,
			User:           cfg.Tunnel.User,
			IdentityFile:   cfg.Tunnel.IdentityFile,
			KnownHostsFile: cfg.Tunnel.KnownHostsFile,
			RemoteBind:     cfg.Tunnel.RemoteBind,
			RemotePort:     cfg.Tunnel.RemotePort,
			KeepAliveSec:   cfg.Tunnel.KeepAliveSec,
		}
		log.Printf("wsmd tunnel enabled -> %s@%s:%d (remote %s:%d)", tc.User, tc.Host, tc.Port, tc.RemoteBind, tc.RemotePort)
		go tunnel.Serve(context.Background(), tc, h)
	}
	srv := &http.Server{Addr: cfg.Addr(), Handler: h}
	if cfg.UsesTLS() {
		log.Printf("wsmd listening on https://%s (mode=%s, ide=%s)", cfg.Addr(), cfg.Mode, cfg.IDE)
		return srv.ListenAndServeTLS(cfg.TLS.Cert, cfg.TLS.Key)
	}
	log.Printf("wsmd listening on http://%s (mode=%s, ide=%s)", cfg.Addr(), cfg.Mode, cfg.IDE)
	return srv.ListenAndServe()
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) windows(w http.ResponseWriter, r *http.Request) {
	profile, _ := s.cfg.ActiveProfile()
	wins, err := s.wm.List(r.Context(), profile)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if wins == nil {
		wins = []api.Window{}
	}
	writeJSON(w, http.StatusOK, api.WindowsResponse{Windows: wins})
}

func (s *server) open(w http.ResponseWriter, r *http.Request) {
	var req api.OpenRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Path == "" {
		writeError(w, http.StatusBadRequest, "path is required")
		return
	}
	profile, _ := s.cfg.ActiveProfile()
	name := req.Name
	if name == "" {
		name = leafOf(req.Path)
	}
	cmd := OpenCommand{
		Host:    req.Host,
		Path:    req.Path,
		Name:    name,
		URI:     resolveURI(profile, req),
		Profile: profile,
	}
	res, err := s.wm.Open(r.Context(), cmd)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *server) focus(w http.ResponseWriter, r *http.Request) {
	var req api.FocusRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.ID == "" && req.Name == "" {
		writeError(w, http.StatusBadRequest, "id or name is required")
		return
	}
	profile, _ := s.cfg.ActiveProfile()
	res, err := s.wm.Focus(r.Context(), FocusCommand{
		ID:      req.ID,
		Name:    req.Name,
		Host:    req.Host,
		Profile: profile,
	})
	if errors.Is(err, ErrWindowNotFound) {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, api.Error{Error: msg})
}
