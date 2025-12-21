// Package pool provides pool management for fireglab runners.
package pool

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/thpham/fireglab/internal/config"
	"github.com/thpham/fireglab/internal/firecracker"
	"github.com/thpham/fireglab/internal/gitlab"
	"github.com/thpham/fireglab/internal/stringid"
)

// RunnerState represents the current state of a runner VM.
type RunnerState string

const (
	RunnerStateStarting RunnerState = "starting"
	RunnerStateIdle     RunnerState = "idle"
	RunnerStateBusy     RunnerState = "busy"
	RunnerStateStopping RunnerState = "stopping"
	RunnerStateStopped  RunnerState = "stopped"
	RunnerStateFailed   RunnerState = "failed"
)

// RunnerInfo contains information about a single runner VM.
type RunnerInfo struct {
	ID             string      `json:"id"`
	Name           string      `json:"name"`
	Status         RunnerState `json:"status"`
	VMID           string      `json:"vm_id,omitempty"`
	IPAddress      string      `json:"ip_address,omitempty"`
	StartedAt      time.Time   `json:"started_at,omitempty"`
	GitLabRunnerID int         `json:"gitlab_runner_id,omitempty"` // Runner ID in GitLab for cleanup
	RunnerToken    string      `json:"-"`                          // glrt-* token (not exposed in API)
}

// PoolStatus contains the current status of a pool.
type PoolStatus struct {
	CurrentRunners int          `json:"current_runners"`
	IdleRunners    int          `json:"idle_runners"`
	BusyRunners    int          `json:"busy_runners"`
	Runners        []RunnerInfo `json:"runners"`
}

// Pool manages a group of runner VMs for a specific configuration.
type Pool struct {
	cfg         *config.PoolConfig
	globalCfg   *config.Config
	gitlab      *gitlab.Client
	vmManager   *firecracker.Manager
	log         *logrus.Logger
	runners     map[string]*RunnerInfo
	mu          sync.RWMutex
	ctx         context.Context
	cancel      context.CancelFunc
	wg          sync.WaitGroup
	scaleTicker *time.Ticker
	scaleSignal chan struct{} // Signal channel for immediate scaling after runner completion
	isActive    bool
}

// New creates a new Pool instance.
func New(cfg *config.PoolConfig, gitlabClient *gitlab.Client, globalCfg *config.Config, log *logrus.Logger) (*Pool, error) {
	vmManager, err := firecracker.NewManager(globalCfg, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create VM manager: %w", err)
	}

	p := &Pool{
		cfg:         cfg,
		globalCfg:   globalCfg,
		gitlab:      gitlabClient,
		vmManager:   vmManager,
		log:         log,
		runners:     make(map[string]*RunnerInfo),
		scaleSignal: make(chan struct{}, 1), // Buffered to avoid blocking monitorRunner
		isActive:    true,
	}

	// Initialize Prometheus metrics for this pool
	metricPoolMaxRunnersCount.WithLabelValues(cfg.Name).Set(float64(cfg.MaxRunners))
	metricPoolMinRunnersCount.WithLabelValues(cfg.Name).Set(float64(cfg.MinRunners))
	metricPoolCurrentRunnersCount.WithLabelValues(cfg.Name).Set(0)
	metricPoolStatus.WithLabelValues(cfg.Name).Set(1)
	metricPoolTotal.Inc()

	return p, nil
}

// Config returns the pool configuration.
func (p *Pool) Config() *config.PoolConfig {
	return p.cfg
}

// Status returns the current pool status.
func (p *Pool) Status() PoolStatus {
	p.mu.RLock()
	defer p.mu.RUnlock()

	status := PoolStatus{
		Runners: make([]RunnerInfo, 0, len(p.runners)),
	}

	for _, r := range p.runners {
		status.CurrentRunners++
		switch r.Status {
		case RunnerStateIdle:
			status.IdleRunners++
		case RunnerStateBusy:
			status.BusyRunners++
		}
		// Copy runner info without exposing token
		info := *r
		info.RunnerToken = ""
		status.Runners = append(status.Runners, info)
	}

	return status
}

// Start begins pool management, ensuring minimum runners are available.
func (p *Pool) Start(ctx context.Context) error {
	p.ctx, p.cancel = context.WithCancel(ctx)

	// Start the scaling loop
	p.scaleTicker = time.NewTicker(10 * time.Second)
	p.wg.Add(1)
	go p.scalingLoop()

	// Initial scale-up to minimum runners
	if err := p.scaleToMinimum(); err != nil {
		p.log.Errorf("Failed to scale to minimum runners: %v", err)
	}

	return nil
}

// Stop gracefully stops the pool and all runners.
// This includes deleting active runners from GitLab and destroying VMs.
func (p *Pool) Stop() error {
	p.cancel()
	if p.scaleTicker != nil {
		p.scaleTicker.Stop()
	}
	p.wg.Wait()

	// Stop all runners
	p.mu.Lock()
	defer p.mu.Unlock()

	// Create a context with timeout for shutdown operations
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for id, runner := range p.runners {
		// Always try to delete runners from GitLab during shutdown if they have a GitLab ID
		// Note: GitLab runners do NOT auto-deregister; they must be deleted via API
		// to prevent orphaned runners appearing offline in GitLab UI
		if runner.GitLabRunnerID != 0 {
			p.log.Infof("Deleting runner %s (GitLab ID: %d, status: %s) from GitLab",
				runner.Name, runner.GitLabRunnerID, runner.Status)
			if err := p.gitlab.DeleteRunner(shutdownCtx, runner.GitLabRunnerID); err != nil {
				p.log.Warnf("Failed to delete runner %s from GitLab: %v", runner.Name, err)
				// Continue with VM destruction even if deletion fails
			}
		} else {
			p.log.Debugf("Skipping GitLab cleanup for runner %s (no GitLab ID assigned, status: %s)",
				id, runner.Status)
		}

		// Destroy the VM if it's still running
		if runner.VMID != "" {
			p.log.Infof("Stopping runner %s (VM: %s)", id, runner.VMID)
			if err := p.vmManager.DestroyVM(runner.VMID); err != nil {
				p.log.Errorf("Failed to destroy VM %s: %v", runner.VMID, err)
			}
		}
	}

	// Close the VM manager
	if p.vmManager != nil {
		if err := p.vmManager.Close(); err != nil {
			p.log.Errorf("Failed to close VM manager: %v", err)
		}
	}

	return nil
}

// Pause pauses the pool. Pausing prevents the pool from scaling.
func (p *Pool) Pause() {
	p.mu.Lock()
	defer p.mu.Unlock()

	if !p.isActive {
		return
	}

	p.log.Infof("Pool %s state changed to paused", p.cfg.Name)
	p.isActive = false
	metricPoolStatus.WithLabelValues(p.cfg.Name).Set(0)
}

// Resume resumes a paused pool. Resuming allows the pool to scale again.
func (p *Pool) Resume() {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.isActive {
		return
	}

	p.log.Infof("Pool %s state changed to active", p.cfg.Name)
	p.isActive = true
	metricPoolStatus.WithLabelValues(p.cfg.Name).Set(1)
}

// IsActive returns whether the pool is active (not paused).
func (p *Pool) IsActive() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.isActive
}

// scalingLoop periodically checks and adjusts the pool size.
func (p *Pool) scalingLoop() {
	defer p.wg.Done()

	for {
		select {
		case <-p.ctx.Done():
			return
		case <-p.scaleTicker.C:
			p.checkAndScale()
		case <-p.scaleSignal:
			// Immediate scale check triggered by runner completion
			p.log.Debug("Immediate scale check triggered by runner completion")
			p.checkAndScale()
		}
	}
}

// checkAndScale evaluates the current state and scales if necessary.
func (p *Pool) checkAndScale() {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Update current runner count metric
	metricPoolCurrentRunnersCount.WithLabelValues(p.cfg.Name).Set(float64(len(p.runners)))

	// Skip scaling if pool is paused
	if !p.isActive {
		p.log.Debugf("Pool %s is paused, skipping scaling", p.cfg.Name)
		return
	}

	// Count current active runners and update metrics
	activeCount := 0
	idleCount := 0
	busyCount := 0
	for _, r := range p.runners {
		if r.Status != RunnerStateStopped && r.Status != RunnerStateFailed {
			activeCount++
		}
		if r.Status == RunnerStateIdle {
			idleCount++
		}
		if r.Status == RunnerStateBusy {
			busyCount++
		}
	}
	metricPoolIdleRunnersCount.WithLabelValues(p.cfg.Name).Set(float64(idleCount))
	metricPoolBusyRunnersCount.WithLabelValues(p.cfg.Name).Set(float64(busyCount))

	// Calculate target runners (for now, maintain minimum)
	// TODO: Implement queue-depth based scaling when GitLab API supports it
	targetRunners := p.cfg.MinRunners

	// Count stopped/failed runners that will be cleaned up and replaced
	stoppedCount := 0
	for _, r := range p.runners {
		if r.Status == RunnerStateStopped || r.Status == RunnerStateFailed {
			stoppedCount++
		}
	}

	p.log.WithFields(logrus.Fields{
		"pool":    p.cfg.Name,
		"active":  activeCount,
		"idle":    idleCount,
		"busy":    busyCount,
		"stopped": stoppedCount,
		"target":  targetRunners,
	}).Debug("Pool scaling check")

	// Scale up if needed
	runnersToSpawn := targetRunners - activeCount
	if runnersToSpawn > 0 {
		if stoppedCount > 0 {
			p.log.WithFields(logrus.Fields{
				"pool":            p.cfg.Name,
				"stopped_runners": stoppedCount,
				"spawning":        runnersToSpawn,
			}).Info("Spawning replacement runners for completed ephemeral runners")
		}

		for i := 0; i < runnersToSpawn; i++ {
			if err := p.spawnRunnerLocked(); err != nil {
				p.log.Errorf("Failed to spawn runner: %v", err)
				break
			}
		}
	}

	// Clean up stopped/failed runners from the map
	for id, r := range p.runners {
		if r.Status == RunnerStateStopped || r.Status == RunnerStateFailed {
			p.log.WithFields(logrus.Fields{
				"runner_id": id,
				"status":    r.Status,
			}).Debug("Removing completed runner from pool tracking")
			delete(p.runners, id)
		}
	}
}

// scaleToMinimum ensures the minimum number of runners are running.
func (p *Pool) scaleToMinimum() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	for i := len(p.runners); i < p.cfg.MinRunners; i++ {
		if err := p.spawnRunnerLocked(); err != nil {
			return fmt.Errorf("failed to spawn runner %d: %w", i, err)
		}
	}

	return nil
}

// spawnRunnerLocked spawns a new runner VM. Caller must hold p.mu.
func (p *Pool) spawnRunnerLocked() error {
	// Generate unique IDs
	uniqueID := stringid.New()
	runnerID := fmt.Sprintf("%s-%s", p.cfg.Name, uniqueID)
	runnerName := stringid.GenerateRunnerName(p.cfg.Name)

	p.log.Infof("Spawning runner: %s", runnerID)
	metricPoolScaleRequests.WithLabelValues(p.cfg.Name).Inc()

	runner := &RunnerInfo{
		ID:        runnerID,
		Name:      runnerName,
		Status:    RunnerStateStarting,
		StartedAt: time.Now(),
	}
	p.runners[runnerID] = runner

	// Create VM asynchronously
	go p.createRunnerVM(runnerID, runnerName)

	return nil
}

// createRunnerVM creates the actual VM for a runner.
// Key difference from fireteact: we CREATE a runner in GitLab first via API,
// then pass the returned glrt-* token to the VM.
func (p *Pool) createRunnerVM(runnerID, runnerName string) {
	startTime := time.Now()

	// Create runner in GitLab via POST /api/v4/user/runners
	// This returns a glrt-* authentication token
	metricGitLabAPIRequests.WithLabelValues(p.cfg.Name, "create_runner").Inc()

	createOpts := gitlab.RunnerOptions{
		RunUntagged:    p.cfg.Runner.RunUntagged,
		Locked:         p.cfg.Runner.Locked,
		AccessLevel:    p.cfg.Runner.AccessLevel,
		MaximumTimeout: p.cfg.Runner.MaximumTimeout,
	}

	description := fmt.Sprintf("fireglab runner %s (pool: %s)", runnerName, p.cfg.Name)
	gitlabRunner, err := p.gitlab.CreateRunner(p.ctx, description, p.cfg.Runner.Tags, createOpts)
	if err != nil {
		p.log.Errorf("Failed to create GitLab runner for %s: %v", runnerID, err)
		p.updateRunnerStatus(runnerID, RunnerStateFailed, "", "", 0, "")
		metricPoolScaleFailures.WithLabelValues(p.cfg.Name).Inc()
		metricGitLabAPIErrors.WithLabelValues(p.cfg.Name, "create_runner").Inc()
		return
	}

	p.log.WithFields(logrus.Fields{
		"runner_id":        runnerID,
		"gitlab_runner_id": gitlabRunner.ID,
	}).Info("Created runner in GitLab")

	// Store GitLab runner ID and token for cleanup
	p.updateRunnerStatus(runnerID, RunnerStateStarting, "", "", gitlabRunner.ID, gitlabRunner.Token)

	// Build runner labels string (comma-separated)
	runnerLabels := joinLabels(p.cfg.Runner.Tags)

	// Generate system ID for this VM instance
	systemID := stringid.GenerateSystemID()

	// Prepare VM configuration with runner metadata
	// Start with pool config metadata (may include user-data from inject-secrets.py)
	metadata := make(map[string]interface{})

	// Copy pool config metadata (includes user-data, instance-id template, etc.)
	for k, v := range p.cfg.Firecracker.Metadata {
		metadata[k] = v
	}

	// Override with per-runner dynamic values
	metadata["instance-id"] = runnerID
	metadata["local-hostname"] = runnerName

	// fireglab metadata - read by fireglab runner agent inside VM
	metadata["fireglab"] = map[string]interface{}{
		"gitlab_instance_url": p.gitlab.GetInstanceURL(),
		"runner_token":        gitlabRunner.Token, // glrt-* token
		"gitlab_runner_id":    gitlabRunner.ID,    // GitLab runner ID for tracking/cleanup
		"runner_name":         runnerName,
		"runner_tags":         runnerLabels,
		"pool_name":           p.cfg.Name,
		"vm_id":               runnerID,
		"system_id":           systemID,
	}

	vmConfig := firecracker.VMConfig{
		ID:         runnerID,
		Name:       runnerName,
		PoolName:   p.cfg.Name,
		MemSizeMib: int64(p.cfg.Firecracker.MemSizeMib),
		VcpuCount:  int64(p.cfg.Firecracker.VcpuCount),
		KernelPath: p.cfg.Firecracker.KernelPath,
		KernelArgs: p.cfg.Firecracker.KernelArgs,
		Image:      p.cfg.Runner.Image,
		Labels:     p.cfg.Runner.Tags,
		Metadata:   metadata,
	}

	// Create the VM
	vm, err := p.vmManager.CreateVM(p.ctx, vmConfig)
	if err != nil {
		p.log.Errorf("Failed to create VM for runner %s: %v", runnerID, err)
		// Clean up the GitLab runner since VM creation failed
		if delErr := p.gitlab.DeleteRunner(p.ctx, gitlabRunner.ID); delErr != nil {
			p.log.Warnf("Failed to cleanup GitLab runner %d after VM creation failure: %v", gitlabRunner.ID, delErr)
		}
		p.updateRunnerStatus(runnerID, RunnerStateFailed, "", "", 0, "")
		metricPoolScaleFailures.WithLabelValues(p.cfg.Name).Inc()
		return
	}

	// Record VM creation time
	metricVMCreationDuration.WithLabelValues(p.cfg.Name).Observe(time.Since(startTime).Seconds())
	metricPoolScaleSuccesses.WithLabelValues(p.cfg.Name).Inc()

	p.log.Infof("Runner %s started with VM %s (IP: %s, GitLab ID: %d)", runnerID, vm.ID, vm.IPAddress, gitlabRunner.ID)
	p.updateRunnerStatusWithVM(runnerID, RunnerStateIdle, vm.ID, vm.IPAddress)

	// Monitor VM lifecycle
	go p.monitorRunner(runnerID, vm.ID, gitlabRunner.ID, startTime)
}

// updateRunnerStatus updates the status of a runner.
func (p *Pool) updateRunnerStatus(runnerID string, status RunnerState, vmID, ipAddress string, gitlabRunnerID int, token string) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if runner, ok := p.runners[runnerID]; ok {
		runner.Status = status
		if vmID != "" {
			runner.VMID = vmID
		}
		if ipAddress != "" {
			runner.IPAddress = ipAddress
		}
		if gitlabRunnerID != 0 {
			runner.GitLabRunnerID = gitlabRunnerID
		}
		if token != "" {
			runner.RunnerToken = token
		}
	}
}

// updateRunnerStatusWithVM updates the status of a runner with VM info.
func (p *Pool) updateRunnerStatusWithVM(runnerID string, status RunnerState, vmID, ipAddress string) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if runner, ok := p.runners[runnerID]; ok {
		runner.Status = status
		if vmID != "" {
			runner.VMID = vmID
		}
		if ipAddress != "" {
			runner.IPAddress = ipAddress
		}
	}
}

// monitorRunner watches a runner VM and cleans up when it exits.
func (p *Pool) monitorRunner(runnerID, vmID string, gitlabRunnerID int, startTime time.Time) {
	// Wait for VM to exit - gitlab-runner in ephemeral mode exits after completing a job
	err := p.vmManager.WaitForExit(p.ctx, vmID)

	lifetime := time.Since(startTime)

	if err != nil && p.ctx.Err() == nil {
		p.log.WithFields(logrus.Fields{
			"runner_id":        runnerID,
			"vm_id":            vmID,
			"gitlab_runner_id": gitlabRunnerID,
			"lifetime":         lifetime.Round(time.Second),
			"error":            err,
		}).Error("Runner VM exited with error")
	} else if p.ctx.Err() != nil {
		p.log.WithFields(logrus.Fields{
			"runner_id":        runnerID,
			"vm_id":            vmID,
			"gitlab_runner_id": gitlabRunnerID,
			"lifetime":         lifetime.Round(time.Second),
		}).Info("Runner stopped due to shutdown signal")
	} else {
		p.log.WithFields(logrus.Fields{
			"runner_id":        runnerID,
			"vm_id":            vmID,
			"gitlab_runner_id": gitlabRunnerID,
			"lifetime":         lifetime.Round(time.Second),
		}).Info("Runner completed job and exited (ephemeral mode)")
	}

	// Record VM lifetime
	metricVMLifetimeDuration.WithLabelValues(p.cfg.Name).Observe(lifetime.Seconds())

	// Delete runner from GitLab if not shutting down
	// In ephemeral mode, the runner may already be auto-deleted, but we try anyway
	if p.ctx.Err() == nil && gitlabRunnerID != 0 {
		metricGitLabAPIRequests.WithLabelValues(p.cfg.Name, "delete_runner").Inc()
		if err := p.gitlab.DeleteRunner(context.Background(), gitlabRunnerID); err != nil {
			p.log.Warnf("Failed to delete GitLab runner %d (may already be deleted): %v", gitlabRunnerID, err)
			metricGitLabAPIErrors.WithLabelValues(p.cfg.Name, "delete_runner").Inc()
		}
	}

	// Mark runner as stopped - this will trigger replacement via scaling loop
	p.updateRunnerStatusWithVM(runnerID, RunnerStateStopped, "", "")

	// Cleanup VM resources (socket, logs, process)
	p.log.WithFields(logrus.Fields{
		"runner_id": runnerID,
		"vm_id":     vmID,
	}).Debug("Cleaning up VM resources")

	if err := p.vmManager.DestroyVM(vmID); err != nil {
		p.log.Warnf("Failed to cleanup VM %s: %v", vmID, err)
	} else {
		p.log.WithFields(logrus.Fields{
			"runner_id": runnerID,
			"vm_id":     vmID,
		}).Info("VM resources cleaned up, runner slot available for replacement")
	}

	// Signal immediate scaling if not shutting down
	if p.ctx.Err() == nil {
		select {
		case p.scaleSignal <- struct{}{}:
			// Signal sent successfully
		default:
			// Channel already has a signal pending, no need to send another
		}
	}
}

// joinLabels joins labels into a comma-separated string.
func joinLabels(labels []string) string {
	result := ""
	for i, l := range labels {
		if i > 0 {
			result += ","
		}
		result += l
	}
	return result
}
