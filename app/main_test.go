package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestRoutes(t *testing.T) {
	h := newServer(config{}).routes()
	for path, want := range map[string]int{
		"/":        http.StatusOK,
		"/healthz": http.StatusOK,
		"/readyz":  http.StatusOK,
		"/metrics": http.StatusOK,
		"/fault":   http.StatusNotFound, // off unless FAULTS_ENABLED
		"/nope":    http.StatusNotFound,
	} {
		if got := get(t, h, path).Code; got != want {
			t.Errorf("GET %s = %d, want %d", path, got, want)
		}
	}
}

func TestMetricsCountRequestsByRouteAndCode(t *testing.T) {
	h := newServer(config{faults: true}).routes()
	get(t, h, "/")
	get(t, h, "/fault")
	get(t, h, "/fault")

	body := get(t, h, "/metrics").Body.String()
	for _, want := range []string{
		`http_requests_total{code="200",route="/"} 1`,
		`http_requests_total{code="500",route="/fault"} 2`,
		`app_build_info{version="dev"} 1`,
		`http_request_duration_seconds_bucket{route="/",le=`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics missing %q", want)
		}
	}
}

func TestReadinessFailsWhenShuttingDown(t *testing.T) {
	s := newServer(config{})
	s.ready.Store(false)
	if got := get(t, s.routes(), "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("readyz = %d, want 503", got)
	}
	if got := get(t, s.routes(), "/healthz").Code; got != http.StatusOK {
		t.Fatalf("healthz = %d, want 200 (liveness must not fail during drain)", got)
	}
}

func TestGracefulShutdown(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	cfg := config{addr: addr, shutdownDelay: 300 * time.Millisecond}
	go func() { done <- run(ctx, cfg, slog.New(slog.NewTextHandler(io.Discard, nil))) }()

	// No keep-alive: an idle pooled connection would hold up Shutdown for its 5s grace period.
	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	url := "http://" + addr
	waitFor(t, func() bool { r, err := client.Get(url + "/healthz"); return err == nil && r.Body.Close() == nil })

	cancel()
	// During the drain delay the server still answers, but readiness is off.
	waitFor(t, func() bool {
		r, err := client.Get(url + "/readyz")
		if err != nil {
			return false
		}
		r.Body.Close()
		return r.StatusCode == http.StatusServiceUnavailable
	})

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop")
	}
}

func TestLoadConfig(t *testing.T) {
	t.Setenv("PORT", "9090")
	t.Setenv("SHUTDOWN_DELAY", "2s")
	t.Setenv("FAULTS_ENABLED", "true")
	c := loadConfig()
	if c.addr != ":9090" || c.shutdownDelay != 2*time.Second || !c.faults {
		t.Fatalf("got %+v", c)
	}
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
