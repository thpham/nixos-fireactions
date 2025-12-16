// Package pool provides pool management for fireteact runners.
package pool

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/thpham/fireteact/internal/config"
	"github.com/thpham/fireteact/internal/firecracker"
	"github.com/thpham/fireteact/internal/gitea"
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
	ID        string      `json:"id"`
	Name      string      `json:"name"`
	Status    RunnerState `json:"status"`
	VMID      string      `json:"vm_id,omitempty"`
	IPAddress string      `json:"ip_address,omitempty"`
	StartedAt time.Time   `json:"started_at,omitempty"`
	JobID     int64       `json:"job_id,omitempty"`
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
	cfg          *config.PoolConfig
	globalCfg    *config.Config
	gitea        *gitea.Client
	vmManager    *firecracker.Manager
	log          *logrus.Logger
	runners      map[string]*RunnerInfo
	mu           sync.RWMutex
	ctx          context.Context
	cancel       context.CancelFunc
	wg           sync.WaitGroup
	scaleTicker  *time.Ticker
	runnerSeq    int
}

// New creates a new Pool instance.
func New(cfg *config.PoolConfig, giteaClient *gitea.Client, globalCfg *config.Config, log *logrus.Logger) (*Pool, error) {
	vmManager, err := firecracker.NewManager(globalCfg, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create VM manager: %w", err)
	}

	return &Pool{
		cfg:       cfg,
		globalCfg: globalCfg,
		gitea:     giteaClient,
		vmManager: vmManager,
		log:       log,
		runners:   make(map[string]*RunnerInfo),
	}, nil
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
		status.Runners = append(status.Runners, *r)
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
func (p *Pool) Stop() error {
	p.cancel()
	if p.scaleTicker != nil {
		p.scaleTicker.Stop()
	}
	p.wg.Wait()

	// Stop all runners
	p.mu.Lock()
	defer p.mu.Unlock()

	for id, runner := range p.runners {
		if runner.VMID != "" {
			p.log.Infof("Stopping runner %s (VM: %s)", id, runner.VMID)
			if err := p.vmManager.DestroyVM(runner.VMID); err != nil {
				p.log.Errorf("Failed to destroy VM %s: %v", runner.VMID, err)
			}
		}
	}

	return nil
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
		}
	}
}

// checkAndScale evaluates the current state and scales if necessary.
func (p *Pool) checkAndScale() {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Count current active runners
	activeCount := 0
	for _, r := range p.runners {
		if r.Status != RunnerStateStopped && r.Status != RunnerStateFailed {
			activeCount++
		}
	}

	// Check queue depth for scaling decisions
	queueDepth, err := p.gitea.GetQueueDepth(p.ctx, p.cfg.Runner.Labels)
	if err != nil {
		p.log.Warnf("Failed to get queue depth: %v", err)
		queueDepth = 0
	}

	// Calculate target runners
	targetRunners := p.cfg.MinRunners
	if queueDepth > 0 {
		// Scale up based on queue depth
		targetRunners = min(p.cfg.MinRunners+queueDepth, p.cfg.MaxRunners)
	}

	p.log.Debugf("Pool %s: active=%d, queue=%d, target=%d", p.cfg.Name, activeCount, queueDepth, targetRunners)

	// Scale up if needed
	for activeCount < targetRunners {
		if err := p.spawnRunnerLocked(); err != nil {
			p.log.Errorf("Failed to spawn runner: %v", err)
			break
		}
		activeCount++
	}

	// Clean up stopped/failed runners
	for id, r := range p.runners {
		if r.Status == RunnerStateStopped || r.Status == RunnerStateFailed {
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
	p.runnerSeq++
	runnerID := fmt.Sprintf("%s-%d", p.cfg.Name, p.runnerSeq)
	runnerName := fmt.Sprintf("%s-%s-%d", p.cfg.Runner.Name, p.cfg.Name, p.runnerSeq)

	p.log.Infof("Spawning runner: %s", runnerID)

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
func (p *Pool) createRunnerVM(runnerID, runnerName string) {
	// Get a fresh registration token for this specific runner
	registrationToken, err := p.gitea.GetRegistrationToken(p.ctx)
	if err != nil {
		p.log.Errorf("Failed to get registration token for runner %s: %v", runnerID, err)
		p.updateRunnerStatus(runnerID, RunnerStateFailed, "", "")
		return
	}

	// Generate cloud-init user-data with the per-runner token
	cloudInitUserData := p.gitea.GenerateCloudInitUserData(
		registrationToken,
		p.cfg.Runner.Labels,
		p.cfg.Name,
	)

	// Prepare VM configuration with runner metadata
	vmConfig := firecracker.VMConfig{
		ID:         runnerID,
		Name:       runnerName,
		MemSizeMib: p.cfg.Firecracker.MemSizeMib,
		VcpuCount:  p.cfg.Firecracker.VcpuCount,
		KernelPath: p.cfg.Firecracker.KernelPath,
		KernelArgs: p.cfg.Firecracker.KernelArgs,
		Image:      p.cfg.Runner.Image,
		Labels:     p.cfg.Runner.Labels,
		Metadata: map[string]string{
			"runner_id":   runnerID,
			"runner_name": runnerName,
			"user-data":   cloudInitUserData,
		},
	}

	// Create the VM
	vm, err := p.vmManager.CreateVM(p.ctx, vmConfig)
	if err != nil {
		p.log.Errorf("Failed to create VM for runner %s: %v", runnerID, err)
		p.updateRunnerStatus(runnerID, RunnerStateFailed, "", "")
		return
	}

	p.log.Infof("Runner %s started with VM %s (IP: %s)", runnerID, vm.ID, vm.IPAddress)
	p.updateRunnerStatus(runnerID, RunnerStateIdle, vm.ID, vm.IPAddress)

	// Monitor VM lifecycle
	go p.monitorRunner(runnerID, vm.ID)
}

// updateRunnerStatus updates the status of a runner.
func (p *Pool) updateRunnerStatus(runnerID string, status RunnerState, vmID, ipAddress string) {
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
func (p *Pool) monitorRunner(runnerID, vmID string) {
	// Wait for VM to exit (this is where the magic happens -
	// act_runner in ephemeral mode will exit after completing a job)
	err := p.vmManager.WaitForExit(p.ctx, vmID)
	if err != nil && p.ctx.Err() == nil {
		p.log.Errorf("Runner %s VM exited with error: %v", runnerID, err)
	} else {
		p.log.Infof("Runner %s completed (VM exited)", runnerID)
	}

	// Mark runner as stopped
	p.updateRunnerStatus(runnerID, RunnerStateStopped, "", "")

	// Cleanup VM resources
	if err := p.vmManager.DestroyVM(vmID); err != nil {
		p.log.Warnf("Failed to cleanup VM %s: %v", vmID, err)
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
