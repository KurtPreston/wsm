// Package wmclient is the canonical Go client for the wsm workspace-management
// API. It is consumed by other projects (docent, grove) to open/focus/list
// workspaces. The request/response types alias libs/api so the client and
// server never drift.
package wmclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/KurtPreston/wsm/libs/api"
)

// Wire types re-exported from libs/api so callers can use wmclient.Window etc.
type (
	Window          = api.Window
	WindowsResponse = api.WindowsResponse
	OpenRequest     = api.OpenRequest
	FocusRequest    = api.FocusRequest
	Result          = api.Result
)

// Client talks to a wsm daemon (wsmd).
type Client struct {
	BaseURL    string
	Token      string
	HTTPClient *http.Client
}

// Option configures a Client.
type Option func(*Client)

// WithToken sets the Bearer token sent on authenticated endpoints.
func WithToken(token string) Option {
	return func(c *Client) { c.Token = token }
}

// WithHTTPClient overrides the default HTTP client.
func WithHTTPClient(hc *http.Client) Option {
	return func(c *Client) { c.HTTPClient = hc }
}

// New returns a Client for baseURL (e.g. http://127.0.0.1:39788).
func New(baseURL string, opts ...Option) *Client {
	c := &Client{
		BaseURL:    strings.TrimRight(baseURL, "/"),
		HTTPClient: &http.Client{Timeout: 30 * time.Second},
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

// ListWindows returns the live workspace windows (GET /windows).
func (c *Client) ListWindows(ctx context.Context) ([]Window, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/windows", nil)
	if err != nil {
		return nil, err
	}
	c.auth(req)
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, statusError("GET /windows", resp)
	}
	var out WindowsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Windows, nil
}

// Open opens (or adopts) a workspace (POST /open).
func (c *Client) Open(ctx context.Context, body OpenRequest) error {
	return c.post(ctx, "/open", body)
}

// Focus focuses an existing workspace window (POST /focus).
func (c *Client) Focus(ctx context.Context, body FocusRequest) error {
	return c.post(ctx, "/focus", body)
}

func (c *Client) post(ctx context.Context, path string, body any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	c.auth(req)
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return statusError("POST "+path, resp)
	}
	return nil
}

func (c *Client) auth(req *http.Request) {
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
}

func statusError(op string, resp *http.Response) error {
	b, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("wsm %s: %s: %s", op, resp.Status, strings.TrimSpace(string(b)))
}

// ParseCursorTitle extracts the workspace leaf and optional SSH host from an
// IDE window title.
func ParseCursorTitle(title string) (leaf, host string) {
	title = strings.TrimSpace(title)
	if title == "" {
		return "", ""
	}
	const marker = "[SSH:"
	if idx := strings.Index(title, marker); idx >= 0 {
		if end := strings.Index(title[idx:], "]"); end > 0 {
			host = strings.TrimSpace(title[idx+len(marker) : idx+end])
			pre := strings.TrimSpace(title[:idx])
			parts := strings.Split(pre, " - ")
			leaf = strings.TrimSpace(parts[len(parts)-1])
			return leaf, host
		}
	}
	core := strings.TrimSuffix(title, " - Cursor")
	parts := strings.Split(core, " - ")
	leaf = strings.TrimSpace(parts[len(parts)-1])
	if leaf == "Cursor" {
		leaf = ""
	}
	return leaf, host
}
