package wmclient_test

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/KurtPreston/wsm/libs/api"
	"github.com/KurtPreston/wsm/libs/webserver"
	"github.com/KurtPreston/wsm/libs/wmclient"
)

// fakeWM is a minimal WindowManager for exercising the client end to end.
type fakeWM struct{ opened api.OpenRequest }

func (f *fakeWM) List(context.Context, webserver.IDEProfile) ([]api.Window, error) {
	return []api.Window{{ID: "1", Title: "proj - Cursor", App: "Cursor"}}, nil
}
func (f *fakeWM) Open(_ context.Context, cmd webserver.OpenCommand) (api.Result, error) {
	f.opened = api.OpenRequest{Host: cmd.Host, Path: cmd.Path, Name: cmd.Name, URI: cmd.URI}
	return api.Result{OK: true, Action: "opened", Name: cmd.Name}, nil
}
func (f *fakeWM) Focus(_ context.Context, cmd webserver.FocusCommand) (api.Result, error) {
	if cmd.Name == "ghost" {
		return api.Result{}, webserver.ErrWindowNotFound
	}
	return api.Result{OK: true, Action: "focused", Name: cmd.Name}, nil
}

func newServer(t *testing.T, wm webserver.WindowManager) *httptest.Server {
	t.Helper()
	cfg := webserver.Default()
	cfg.Token = "tok"
	h, err := webserver.NewHandler(cfg, wm)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	return httptest.NewServer(h)
}

func TestClientRoundTrip(t *testing.T) {
	wm := &fakeWM{}
	srv := newServer(t, wm)
	defer srv.Close()

	c := wmclient.New(srv.URL, wmclient.WithToken("tok"))
	ctx := context.Background()

	wins, err := c.ListWindows(ctx)
	if err != nil {
		t.Fatalf("ListWindows: %v", err)
	}
	if len(wins) != 1 || wins[0].ID != "1" {
		t.Fatalf("windows = %+v", wins)
	}

	if err := c.Open(ctx, wmclient.OpenRequest{Host: "devbox", Path: "/x/proj"}); err != nil {
		t.Fatalf("Open: %v", err)
	}
	if wm.opened.URI != "vscode-remote://ssh-remote+devbox/x/proj" {
		t.Fatalf("server resolved uri = %q", wm.opened.URI)
	}

	if err := c.Focus(ctx, wmclient.FocusRequest{Name: "proj"}); err != nil {
		t.Fatalf("Focus: %v", err)
	}
	if err := c.Focus(ctx, wmclient.FocusRequest{Name: "ghost"}); err == nil {
		t.Fatal("expected error focusing a missing window")
	}
}

func TestClientNoTokenRejected(t *testing.T) {
	srv := newServer(t, &fakeWM{})
	defer srv.Close()

	c := wmclient.New(srv.URL) // no token
	if _, err := c.ListWindows(context.Background()); err == nil {
		t.Fatal("expected 401 without a token")
	}
}
