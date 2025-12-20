// Package server provides the HTTP server and pool orchestration for fireglab.
package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sirupsen/logrus"
	"github.com/thpham/fireglab/internal/config"
	"github.com/thpham/fireglab/internal/gitlab"
	"github.com/thpham/fireglab/internal/pool"
)

// Server is the main fireglab server that manages pools and exposes HTTP APIs.
type Server struct {
	cfg    *config.Config
	log    *logrus.Logger
	pools  map[string]*pool.Pool
	gitlab *gitlab.Client
	mu     sync.RWMutex
}

// New creates a new Server instance.
func New(cfg *config.Config, log *logrus.Logger) (*Server, error) {
	// Create GitLab client for runner management via POST /user/runners
	gitlabClient, err := gitlab.NewClient(
		cfg.GitLab.InstanceURL,
		cfg.GetAccessToken(),
		cfg.GitLab.RunnerType,
		cfg.GitLab.GroupID,
		cfg.GitLab.ProjectID,
		log,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create GitLab client: %w", err)
	}

	s := &Server{
		cfg:    cfg,
		log:    log,
		pools:  make(map[string]*pool.Pool),
		gitlab: gitlabClient,
	}

	// Initialize pools
	for _, poolCfg := range cfg.Pools {
		p, err := pool.New(&poolCfg, gitlabClient, cfg, log)
		if err != nil {
			return nil, fmt.Errorf("failed to create pool %s: %w", poolCfg.Name, err)
		}
		s.pools[poolCfg.Name] = p
	}

	return s, nil
}

// Run starts the server and blocks until the context is cancelled.
func (s *Server) Run(ctx context.Context) error {
	// Start all pools
	for name, p := range s.pools {
		s.log.Infof("Starting pool: %s (min: %d, max: %d)", name, p.Config().MinRunners, p.Config().MaxRunners)
		if err := p.Start(ctx); err != nil {
			return fmt.Errorf("failed to start pool %s: %w", name, err)
		}
	}

	// Start HTTP servers
	errChan := make(chan error, 2)

	// Main API server
	apiServer := &http.Server{
		Addr:    s.cfg.Server.Address,
		Handler: s.apiRouter(),
	}

	go func() {
		s.log.Infof("Starting API server on %s", s.cfg.Server.Address)
		if err := apiServer.ListenAndServe(); err != http.ErrServerClosed {
			errChan <- fmt.Errorf("API server error: %w", err)
		}
	}()

	// Metrics server
	metricsServer := &http.Server{
		Addr:    s.cfg.Server.MetricsAddress,
		Handler: promhttp.Handler(),
	}

	go func() {
		s.log.Infof("Starting metrics server on %s", s.cfg.Server.MetricsAddress)
		if err := metricsServer.ListenAndServe(); err != http.ErrServerClosed {
			errChan <- fmt.Errorf("metrics server error: %w", err)
		}
	}()

	// Wait for shutdown signal or error
	select {
	case <-ctx.Done():
		s.log.Info("Shutting down servers...")
	case err := <-errChan:
		return err
	}

	// Graceful shutdown
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Stop all pools
	for name, p := range s.pools {
		s.log.Infof("Stopping pool: %s", name)
		if err := p.Stop(); err != nil {
			s.log.Errorf("Error stopping pool %s: %v", name, err)
		}
	}

	// Shutdown HTTP servers
	if err := apiServer.Shutdown(shutdownCtx); err != nil {
		s.log.Errorf("Error shutting down API server: %v", err)
	}
	if err := metricsServer.Shutdown(shutdownCtx); err != nil {
		s.log.Errorf("Error shutting down metrics server: %v", err)
	}

	return nil
}

// apiRouter creates the HTTP router for the API server.
func (s *Server) apiRouter() http.Handler {
	mux := http.NewServeMux()

	// Health check
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/healthz", s.handleHealth)

	// Pool status
	mux.HandleFunc("/api/v1/pools", s.handlePoolList)
	mux.HandleFunc("/api/v1/pools/", s.handlePoolDetail)

	// Runner management
	mux.HandleFunc("/api/v1/runners", s.handleRunnerList)

	return mux
}

// handleHealth returns server health status.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "healthy",
	})
}

// handlePoolList returns all pools and their status.
func (s *Server) handlePoolList(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	pools := make([]map[string]interface{}, 0, len(s.pools))
	for name, p := range s.pools {
		status := p.Status()
		pools = append(pools, map[string]interface{}{
			"name":           name,
			"minRunners":     p.Config().MinRunners,
			"maxRunners":     p.Config().MaxRunners,
			"currentRunners": status.CurrentRunners,
			"idleRunners":    status.IdleRunners,
			"busyRunners":    status.BusyRunners,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"pools": pools,
	})
}

// handlePoolDetail returns details for a specific pool.
func (s *Server) handlePoolDetail(w http.ResponseWriter, r *http.Request) {
	// Extract pool name from URL path
	poolName := r.URL.Path[len("/api/v1/pools/"):]
	if poolName == "" {
		http.Error(w, "Pool name required", http.StatusBadRequest)
		return
	}

	s.mu.RLock()
	p, ok := s.pools[poolName]
	s.mu.RUnlock()

	if !ok {
		http.Error(w, "Pool not found", http.StatusNotFound)
		return
	}

	status := p.Status()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"name":           poolName,
		"minRunners":     p.Config().MinRunners,
		"maxRunners":     p.Config().MaxRunners,
		"currentRunners": status.CurrentRunners,
		"idleRunners":    status.IdleRunners,
		"busyRunners":    status.BusyRunners,
		"runners":        status.Runners,
	})
}

// handleRunnerList returns all runners across all pools.
func (s *Server) handleRunnerList(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	runners := make([]map[string]interface{}, 0)
	for poolName, p := range s.pools {
		status := p.Status()
		for _, runner := range status.Runners {
			runners = append(runners, map[string]interface{}{
				"pool":             poolName,
				"id":               runner.ID,
				"name":             runner.Name,
				"status":           runner.Status,
				"gitlab_runner_id": runner.GitLabRunnerID,
			})
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"runners": runners,
	})
}
