// Command app is the small HTTP service the templates deploy. It exists to exercise the
// infrastructure: probes, graceful shutdown, Prometheus metrics and an optional fault endpoint
// for testing alerts.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// version is set at build time: -ldflags "-X main.version=1.2.3".
var version = "dev"

type config struct {
	addr          string
	shutdownDelay time.Duration
	faults        bool
}

func loadConfig() config {
	c := config{addr: ":8080", shutdownDelay: 5 * time.Second}
	if p := os.Getenv("PORT"); p != "" {
		c.addr = ":" + p
	}
	if d, err := time.ParseDuration(os.Getenv("SHUTDOWN_DELAY")); err == nil {
		c.shutdownDelay = d
	}
	c.faults, _ = strconv.ParseBool(os.Getenv("FAULTS_ENABLED"))
	return c
}

type server struct {
	cfg      config
	ready    atomic.Bool
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	latency  *prometheus.HistogramVec
}

func newServer(cfg config) *server {
	s := &server{
		cfg:      cfg,
		registry: prometheus.NewRegistry(),
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests by route and status code.",
		}, []string{"route", "code"}),
		latency: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency by route.",
			Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5},
		}, []string{"route"}),
	}
	build := prometheus.NewGauge(prometheus.GaugeOpts{
		Name:        "app_build_info",
		Help:        "Always 1; the version label says what is running.",
		ConstLabels: prometheus.Labels{"version": version},
	})
	build.Set(1)
	s.registry.MustRegister(s.requests, s.latency, build,
		collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	s.ready.Store(true)
	return s
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /{$}", s.instrument("/", s.index))
	mux.Handle("GET /healthz", s.instrument("/healthz", s.healthz))
	mux.Handle("GET /readyz", s.instrument("/readyz", s.readyz))
	if s.cfg.faults {
		mux.Handle("GET /fault", s.instrument("/fault", s.fault))
	}
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.registry, promhttp.HandlerOpts{}))
	return mux
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *server) instrument(route string, h http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		s.latency.WithLabelValues(route).Observe(time.Since(start).Seconds())
		s.requests.WithLabelValues(route, strconv.Itoa(rec.code)).Inc()
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	host, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]string{"service": "app", "version": version, "host": host})
}

// healthz is the liveness probe: the process is up and serving.
func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is the readiness probe. It turns 503 when shutdown starts, so the pod leaves the
// Service endpoints before the listener closes.
func (s *server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting down"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// fault always fails. Only mounted with FAULTS_ENABLED=true, to fire the error-rate alert on purpose.
func (s *server) fault(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "injected fault"})
}

func run(ctx context.Context, cfg config, log *slog.Logger) error {
	s := newServer(cfg)
	srv := &http.Server{
		Addr:              cfg.addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("listening", "addr", cfg.addr, "version", version, "faults", cfg.faults)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}

	// Fail readiness first and give the endpoints controller time to drop this pod.
	s.ready.Store(false)
	log.Info("shutting down", "drain", cfg.shutdownDelay)
	time.Sleep(cfg.shutdownDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, loadConfig(), log); err != nil {
		log.Error("server failed", "err", err)
		os.Exit(1)
	}
}
