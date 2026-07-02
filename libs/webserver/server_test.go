package webserver

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/KurtPreston/wsm/libs/api"
)

// stubWM is a scriptable WindowManager for handler tests.
type stubWM struct {
	windows     []api.Window
	lastOpen    OpenCommand
	lastOpenURL OpenURLCommand
	openErr     error
	focusErr    error
	openURLErr  error
}

func (s *stubWM) List(context.Context, IDEProfile) ([]api.Window, error) {
	return s.windows, nil
}
func (s *stubWM) Open(_ context.Context, cmd OpenCommand) (api.Result, error) {
	s.lastOpen = cmd
	if s.openErr != nil {
		return api.Result{}, s.openErr
	}
	return api.Result{OK: true, Action: "opened", Name: cmd.Name}, nil
}
func (s *stubWM) Focus(_ context.Context, cmd FocusCommand) (api.Result, error) {
	if s.focusErr != nil {
		return api.Result{}, s.focusErr
	}
	return api.Result{OK: true, Action: "focused", Name: cmd.Name}, nil
}
func (s *stubWM) OpenURL(_ context.Context, cmd OpenURLCommand) (api.Result, error) {
	s.lastOpenURL = cmd
	if s.openURLErr != nil {
		return api.Result{}, s.openURLErr
	}
	return api.Result{OK: true, Action: "opened", Name: cmd.Name}, nil
}

func testConfig() Config {
	c := Default()
	c.Token = "s3cret"
	return c
}

func newTestServer(t *testing.T, wm WindowManager) *httptest.Server {
	t.Helper()
	h, err := NewHandler(testConfig(), wm)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	return httptest.NewServer(h)
}

func TestHealthNoAuth(t *testing.T) {
	srv := newTestServer(t, &stubWM{})
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("health status = %d", resp.StatusCode)
	}
}

func TestWindowsRequiresAuth(t *testing.T) {
	srv := newTestServer(t, &stubWM{})
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/windows")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /windows = %d, want 401", resp.StatusCode)
	}
}

func TestWindowsAuthedReturnsList(t *testing.T) {
	wm := &stubWM{windows: []api.Window{{ID: "1", Title: "feat - Cursor", App: "Cursor"}}}
	srv := newTestServer(t, wm)
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/windows", nil)
	req.Header.Set("Authorization", "Bearer s3cret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var out api.WindowsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if len(out.Windows) != 1 || out.Windows[0].ID != "1" {
		t.Fatalf("unexpected windows: %+v", out.Windows)
	}
}

func TestWrongTokenRejected(t *testing.T) {
	srv := newTestServer(t, &stubWM{})
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/windows", nil)
	req.Header.Set("Authorization", "Bearer nope")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token = %d, want 401", resp.StatusCode)
	}
}

func TestOpenResolvesRemoteURIAndName(t *testing.T) {
	wm := &stubWM{}
	srv := newTestServer(t, wm)
	defer srv.Close()

	body := `{"host":"devbox","path":"/home/me/Code/salsa/my-feature"}`
	req, _ := http.NewRequest("POST", srv.URL+"/open", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer s3cret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if wm.lastOpen.Name != "my-feature" {
		t.Errorf("name = %q, want my-feature (derived from path leaf)", wm.lastOpen.Name)
	}
	want := "vscode-remote://ssh-remote+devbox/home/me/Code/salsa/my-feature"
	if wm.lastOpen.URI != want {
		t.Errorf("uri = %q, want %q", wm.lastOpen.URI, want)
	}
}

func TestOpenLocalURI(t *testing.T) {
	wm := &stubWM{}
	srv := newTestServer(t, wm)
	defer srv.Close()

	body := `{"path":"/home/me/proj","name":"proj"}`
	req, _ := http.NewRequest("POST", srv.URL+"/open", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer s3cret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if want := "file:///home/me/proj"; wm.lastOpen.URI != want {
		t.Errorf("local uri = %q, want %q", wm.lastOpen.URI, want)
	}
}

func TestOpenMissingPath(t *testing.T) {
	srv := newTestServer(t, &stubWM{})
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/open", strings.NewReader(`{"host":"x"}`))
	req.Header.Set("Authorization", "Bearer s3cret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing path = %d, want 400", resp.StatusCode)
	}
}

func TestFocusNotFound(t *testing.T) {
	wm := &stubWM{focusErr: ErrWindowNotFound}
	srv := newTestServer(t, wm)
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/focus", strings.NewReader(`{"name":"ghost"}`))
	req.Header.Set("Authorization", "Bearer s3cret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("focus miss = %d, want 404", resp.StatusCode)
	}
}

func TestPreflightOPTIONS(t *testing.T) {
	srv := newTestServer(t, &stubWM{})
	defer srv.Close()

	req, _ := http.NewRequest("OPTIONS", srv.URL+"/open", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("preflight = %d, want 204", resp.StatusCode)
	}
	if resp.Header.Get("Access-Control-Allow-Headers") == "" {
		t.Error("missing CORS allow-headers")
	}
}
