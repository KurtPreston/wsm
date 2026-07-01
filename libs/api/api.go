// Package api defines the wire types for the wsm workspace-management API.
//
// These types are the Go mirror of openapi/v1/openapi.yaml and are the single
// source of truth shared by the server (libs/webserver), the client
// (libs/wmclient), and the platform apps. Keep them in sync with the spec; the
// contract test in libs/webserver validates live responses against the YAML.
package api

// DefaultPort is the loopback port wsmd binds by default.
const DefaultPort = 39788

// Window describes an open workspace (IDE) window.
type Window struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	App   string `json:"app"`
	Host  string `json:"host,omitempty"`
}

// WindowsResponse is the body returned by GET /windows.
type WindowsResponse struct {
	Windows []Window `json:"windows"`
}

// OpenRequest is the body for POST /open.
type OpenRequest struct {
	Host string `json:"host"`
	Path string `json:"path"`
	Name string `json:"name"`
	URI  string `json:"uri,omitempty"`
}

// FocusRequest is the body for POST /focus.
type FocusRequest struct {
	ID   string `json:"id,omitempty"`
	Name string `json:"name,omitempty"`
	Host string `json:"host,omitempty"`
}

// Result is the success body returned by POST /open and POST /focus.
type Result struct {
	OK     bool   `json:"ok"`
	Action string `json:"action"`
	Name   string `json:"name"`
}

// Error is the JSON error body returned with non-2xx responses.
type Error struct {
	Error string `json:"error"`
}
