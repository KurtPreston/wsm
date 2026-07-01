package webserver

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/KurtPreston/wsm/libs/api"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/gorillamux"
)

const specPath = "../../openapi/v1/openapi.yaml"

// loadContractRouter loads and validates openapi/v1/openapi.yaml and returns a
// host-agnostic router for matching live requests to their spec operations.
func loadContractRouter(t *testing.T) routers.Router {
	t.Helper()
	loader := openapi3.NewLoader()
	loader.IsExternalRefsAllowed = true
	doc, err := loader.LoadFromFile(specPath)
	if err != nil {
		t.Fatalf("load spec: %v", err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("spec is not a valid OpenAPI document: %v", err)
	}
	// Route on path only, independent of the httptest server's random host:port.
	doc.Servers = openapi3.Servers{{URL: "/"}}
	r, err := gorillamux.NewRouter(doc)
	if err != nil {
		t.Fatalf("build router: %v", err)
	}
	return r
}

// validateExchange runs one request against the live handler and validates both
// the request and the response against the OpenAPI contract.
func validateExchange(t *testing.T, router routers.Router, base, method, path, token, body string, wantStatus int) {
	t.Helper()

	var reqBody io.Reader
	if body != "" {
		reqBody = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, base+path, reqBody)
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	route, pathParams, err := router.FindRoute(req)
	if err != nil {
		t.Fatalf("%s %s: no matching route in spec: %v", method, path, err)
	}

	// Rebuild the request body reader for both validation and the live call.
	if body != "" {
		req.Body = io.NopCloser(strings.NewReader(body))
	}
	reqInput := &openapi3filter.RequestValidationInput{
		Request:    req,
		PathParams: pathParams,
		Route:      route,
		Options: &openapi3filter.Options{
			AuthenticationFunc: openapi3filter.NoopAuthenticationFunc,
		},
	}
	if err := openapi3filter.ValidateRequest(context.Background(), reqInput); err != nil {
		t.Fatalf("%s %s: request violates contract: %v", method, path, err)
	}

	// Perform the live call.
	live, err := http.NewRequest(method, base+path, bodyReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		live.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		live.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(live)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != wantStatus {
		t.Fatalf("%s %s: status = %d, want %d (body %q)", method, path, resp.StatusCode, wantStatus, respBody)
	}

	respInput := &openapi3filter.ResponseValidationInput{
		RequestValidationInput: reqInput,
		Status:                 resp.StatusCode,
		Header:                 resp.Header,
		Options:                reqInput.Options,
	}
	respInput.SetBodyBytes(respBody)
	if err := openapi3filter.ValidateResponse(context.Background(), respInput); err != nil {
		t.Fatalf("%s %s -> %d: response violates contract: %v", method, path, resp.StatusCode, err)
	}
}

func bodyReader(body string) io.Reader {
	if body == "" {
		return nil
	}
	return bytes.NewReader([]byte(body))
}

func TestContractCompliance(t *testing.T) {
	router := loadContractRouter(t)

	wm := &stubWM{windows: []api.Window{
		{ID: "1", Title: "my-feature [SSH: devbox] - Cursor", App: "Cursor", Host: "devbox"},
	}}
	h, err := NewHandler(testConfig(), wm)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	const tok = "s3cret"

	validateExchange(t, router, srv.URL, "GET", "/health", "", "", http.StatusOK)
	validateExchange(t, router, srv.URL, "GET", "/windows", tok, "", http.StatusOK)
	validateExchange(t, router, srv.URL, "POST", "/open", tok,
		`{"host":"devbox","path":"/home/me/Code/proj","name":"proj"}`, http.StatusOK)

	// Focus miss must be a spec-compliant 404 Error body.
	wm.focusErr = ErrWindowNotFound
	validateExchange(t, router, srv.URL, "POST", "/focus", tok, `{"name":"ghost"}`, http.StatusNotFound)
}
