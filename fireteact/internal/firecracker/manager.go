// Package firecracker provides Firecracker VM management for fireteact.
package firecracker

import (
	"context"
	"fmt"
	"sync"

	"github.com/sirupsen/logrus"
	"github.com/thpham/fireteact/internal/config"
)

// VMConfig contains the configuration for creating a VM.
type VMConfig struct {
	ID         string
	Name       string
	MemSizeMib int
	VcpuCount  int
	KernelPath string
	KernelArgs string
	Image      string
	Labels     []string
	Metadata   map[string]string
}

// VM represents a running Firecracker VM.
type VM struct {
	ID        string
	Name      string
	IPAddress string
	SocketPath string
}

// Manager handles Firecracker VM lifecycle.
type Manager struct {
	cfg       *config.Config
	log       *logrus.Logger
	vms       map[string]*VM
	mu        sync.RWMutex
	vmSeq     int
}

// NewManager creates a new Firecracker VM manager.
func NewManager(cfg *config.Config, log *logrus.Logger) (*Manager, error) {
	return &Manager{
		cfg: cfg,
		log: log,
		vms: make(map[string]*VM),
	}, nil
}

// CreateVM creates and starts a new Firecracker VM.
func (m *Manager) CreateVM(ctx context.Context, vmCfg VMConfig) (*VM, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.vmSeq++
	vmID := fmt.Sprintf("fireteact-%s-%d", vmCfg.ID, m.vmSeq)

	m.log.Infof("Creating VM %s with %d MiB RAM and %d vCPUs", vmID, vmCfg.MemSizeMib, vmCfg.VcpuCount)

	// TODO: Implement actual Firecracker VM creation
	// This will involve:
	// 1. Pull container image using containerd
	// 2. Extract rootfs from container image
	// 3. Create Firecracker VM configuration
	// 4. Setup networking via CNI
	// 5. Configure MMDS with metadata
	// 6. Start the VM
	//
	// For now, this is a placeholder implementation

	vm := &VM{
		ID:         vmID,
		Name:       vmCfg.Name,
		IPAddress:  "10.200.0.100", // Placeholder
		SocketPath: fmt.Sprintf("/run/firecracker/%s.sock", vmID),
	}

	m.vms[vmID] = vm

	m.log.Infof("VM %s created successfully", vmID)
	return vm, nil
}

// DestroyVM stops and cleans up a Firecracker VM.
func (m *Manager) DestroyVM(vmID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	vm, ok := m.vms[vmID]
	if !ok {
		return fmt.Errorf("VM %s not found", vmID)
	}

	m.log.Infof("Destroying VM %s", vmID)

	// TODO: Implement actual VM destruction
	// This will involve:
	// 1. Send shutdown signal to VM
	// 2. Wait for graceful shutdown (with timeout)
	// 3. Force kill if needed
	// 4. Cleanup CNI networking
	// 5. Remove rootfs and socket

	delete(m.vms, vmID)
	m.log.Infof("VM %s destroyed", vm.ID)

	return nil
}

// WaitForExit blocks until the VM exits or the context is cancelled.
func (m *Manager) WaitForExit(ctx context.Context, vmID string) error {
	m.mu.RLock()
	_, ok := m.vms[vmID]
	m.mu.RUnlock()

	if !ok {
		return fmt.Errorf("VM %s not found", vmID)
	}

	// TODO: Implement actual wait for VM exit
	// This will monitor the Firecracker process and wait for it to exit.
	// The VM will exit when act_runner completes its job (in ephemeral mode).

	// For now, just wait for context cancellation
	<-ctx.Done()
	return ctx.Err()
}

// GetVM returns information about a specific VM.
func (m *Manager) GetVM(vmID string) (*VM, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	vm, ok := m.vms[vmID]
	if !ok {
		return nil, fmt.Errorf("VM %s not found", vmID)
	}

	return vm, nil
}

// ListVMs returns all running VMs.
func (m *Manager) ListVMs() []*VM {
	m.mu.RLock()
	defer m.mu.RUnlock()

	vms := make([]*VM, 0, len(m.vms))
	for _, vm := range m.vms {
		vms = append(vms, vm)
	}

	return vms
}
