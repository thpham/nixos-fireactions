// Package firecracker provides Firecracker VM management for fireteact.
package firecracker

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/containerd/containerd"
	"github.com/containerd/containerd/leases"
	"github.com/containerd/containerd/mount"
	"github.com/containerd/errdefs"
	"github.com/containerd/nerdctl/pkg/imgutil/dockerconfigresolver"
	"github.com/distribution/reference"
	"github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/opencontainers/image-spec/identity"
	"github.com/sirupsen/logrus"
	"github.com/thpham/fireteact/internal/config"
	"github.com/thpham/fireteact/internal/stringid"
)

const (
	// DefaultSnapshotter is the default containerd snapshotter for rootfs.
	DefaultSnapshotter = "devmapper"
	// DefaultNetworkName is the default CNI network name.
	DefaultNetworkName = "fireteact"
	// DefaultPoolDir is the base directory for pool data.
	DefaultPoolDir = "/var/lib/fireteact/pools"
)

// VMConfig contains the configuration for creating a VM.
type VMConfig struct {
	ID         string
	Name       string
	PoolName   string
	MemSizeMib int64
	VcpuCount  int64
	KernelPath string
	KernelArgs string
	Image      string
	Labels     []string
	Metadata   map[string]interface{}
}

// VM represents a running Firecracker VM.
type VM struct {
	ID          string
	Name        string
	IPAddress   string
	SocketPath  string
	machine     *firecracker.Machine
	leaseCancel func(context.Context) error
	logFile     *os.File
}

// Manager handles Firecracker VM lifecycle with containerd integration.
type Manager struct {
	cfg          *config.Config
	log          *logrus.Logger
	containerd   *containerd.Client
	containerdMu sync.Mutex
	vms          map[string]*VM
	vmsMu        sync.RWMutex
	poolDirs     map[string]string
}

// NewManager creates a new Firecracker VM manager.
func NewManager(cfg *config.Config, log *logrus.Logger) (*Manager, error) {
	// Connect to containerd
	client, err := containerd.New(
		cfg.Containerd.Address,
		containerd.WithDefaultNamespace(cfg.Containerd.Namespace),
		containerd.WithTimeout(10*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to containerd: %w", err)
	}

	m := &Manager{
		cfg:        cfg,
		log:        log,
		containerd: client,
		vms:        make(map[string]*VM),
		poolDirs:   make(map[string]string),
	}

	// Ensure base pool directory exists
	if err := os.MkdirAll(DefaultPoolDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create pool directory: %w", err)
	}

	// Clean up stale resources from previous runs
	m.cleanupStaleResources()

	return m, nil
}

// cleanupStaleResources removes orphaned socket and log files from previous runs.
// This is called on startup to clean up after unclean shutdowns.
func (m *Manager) cleanupStaleResources() {
	// Scan all pool directories
	entries, err := os.ReadDir(DefaultPoolDir)
	if err != nil {
		m.log.Warnf("Failed to read pool directory %s: %v", DefaultPoolDir, err)
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		poolDir := filepath.Join(DefaultPoolDir, entry.Name())
		m.cleanupPoolDirectory(poolDir)
	}
}

// cleanupPoolDirectory removes stale socket and log files from a pool directory.
func (m *Manager) cleanupPoolDirectory(poolDir string) {
	files, err := os.ReadDir(poolDir)
	if err != nil {
		m.log.Warnf("Failed to read pool directory %s: %v", poolDir, err)
		return
	}

	for _, file := range files {
		if file.IsDir() {
			continue
		}

		// Only check socket files
		if filepath.Ext(file.Name()) != ".sock" {
			continue
		}

		socketPath := filepath.Join(poolDir, file.Name())

		// Try to connect to the socket to check if firecracker is still running
		if m.isSocketActive(socketPath) {
			m.log.Debugf("Socket %s is still active, skipping cleanup", socketPath)
			continue
		}

		// Socket is stale, remove it and the corresponding log file
		m.log.Infof("Removing stale socket: %s", socketPath)
		if err := os.Remove(socketPath); err != nil {
			m.log.Warnf("Failed to remove stale socket %s: %v", socketPath, err)
		}

		// Also remove corresponding log file
		logPath := socketPath[:len(socketPath)-5] + ".log" // Replace .sock with .log
		if _, err := os.Stat(logPath); err == nil {
			m.log.Infof("Removing stale log: %s", logPath)
			if err := os.Remove(logPath); err != nil {
				m.log.Warnf("Failed to remove stale log %s: %v", logPath, err)
			}
		}
	}
}

// isSocketActive checks if a socket file has an active firecracker process.
func (m *Manager) isSocketActive(socketPath string) bool {
	// Try to connect to the socket with a short timeout
	conn, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
	if err != nil {
		// Connection failed - socket is stale
		return false
	}
	conn.Close()
	return true
}

// Close closes the manager and releases resources.
func (m *Manager) Close() error {
	if m.containerd != nil {
		return m.containerd.Close()
	}
	return nil
}

// GetPoolDir returns the directory for a pool's sockets and logs.
func (m *Manager) GetPoolDir(poolName string) string {
	if dir, ok := m.poolDirs[poolName]; ok {
		return dir
	}
	dir := filepath.Join(DefaultPoolDir, poolName)
	m.poolDirs[poolName] = dir
	return dir
}

// EnsurePoolDir creates the pool directory if it doesn't exist.
func (m *Manager) EnsurePoolDir(poolName string) error {
	dir := m.GetPoolDir(poolName)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create pool directory %s: %w", dir, err)
	}
	return nil
}

// CreateVM creates and starts a new Firecracker VM.
func (m *Manager) CreateVM(ctx context.Context, vmCfg VMConfig) (*VM, error) {
	// Generate unique VM ID using random hex string (collision-resistant)
	vmID := fmt.Sprintf("%s-%s", vmCfg.ID, stringid.New())

	m.log.Infof("Creating VM %s with %d MiB RAM and %d vCPUs", vmID, vmCfg.MemSizeMib, vmCfg.VcpuCount)

	// Ensure pool directory exists
	if err := m.EnsurePoolDir(vmCfg.PoolName); err != nil {
		return nil, err
	}
	poolDir := m.GetPoolDir(vmCfg.PoolName)

	// Pull or get image
	image, err := m.ensureImage(ctx, vmCfg.Image, vmCfg.PoolName)
	if err != nil {
		return nil, fmt.Errorf("failed to ensure image: %w", err)
	}

	// Create containerd lease for this VM
	leaseID := fmt.Sprintf("fireteact/pools/%s/%s", vmCfg.PoolName, vmID)
	leaseCtx, leaseCancel, err := m.containerd.WithLease(ctx, leases.WithID(leaseID))
	if err != nil {
		return nil, fmt.Errorf("failed to create containerd lease: %w", err)
	}

	// Create snapshot from image
	snapshotMounts, err := m.createSnapshot(leaseCtx, image, vmID)
	if err != nil {
		_ = leaseCancel(ctx)
		return nil, fmt.Errorf("failed to create snapshot: %w", err)
	}

	// Create log file for VM
	logFilePath := filepath.Join(poolDir, fmt.Sprintf("%s.log", vmID))
	logFile, err := os.Create(logFilePath)
	if err != nil {
		_ = leaseCancel(ctx)
		return nil, fmt.Errorf("failed to create log file: %w", err)
	}

	// Build Firecracker command
	socketPath := filepath.Join(poolDir, fmt.Sprintf("%s.sock", vmID))
	firecrackerBin := m.getFirecrackerBinary(vmCfg.PoolName)

	machineCmd := firecracker.VMCommandBuilder{}.
		WithSocketPath(socketPath).
		WithStderr(logFile).
		WithStdout(logFile).
		WithBin(firecrackerBin).
		Build(context.Background())

	// Suppress firecracker-go-sdk internal logging
	fcLogger := logrus.New()
	fcLogger.SetLevel(logrus.WarnLevel)
	fcLogger.SetOutput(io.Discard)

	// Determine kernel path
	kernelPath := vmCfg.KernelPath
	if kernelPath == "" {
		kernelPath = m.cfg.Pools[0].Firecracker.KernelPath // fallback
	}

	// Create Firecracker machine configuration
	vcpuCount := vmCfg.VcpuCount
	memSizeMib := vmCfg.MemSizeMib

	machine, err := firecracker.NewMachine(ctx, firecracker.Config{
		VMID:            vmID,
		SocketPath:      socketPath,
		KernelImagePath: kernelPath,
		KernelArgs:      vmCfg.KernelArgs,
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  &vcpuCount,
			MemSizeMib: &memSizeMib,
		},
		Drives: []models.Drive{{
			DriveID:      firecracker.String("rootfs"),
			PathOnHost:   &snapshotMounts[0].Source,
			IsRootDevice: firecracker.Bool(true),
			IsReadOnly:   firecracker.Bool(false),
		}},
		NetworkInterfaces: []firecracker.NetworkInterface{{
			AllowMMDS: true,
			CNIConfiguration: &firecracker.CNIConfiguration{
				NetworkName: DefaultNetworkName,
				IfName:      "eth0",
				ConfDir:     m.cfg.CNI.ConfDir,
				BinPath:     []string{m.cfg.CNI.BinDir},
			},
		}},
		MmdsAddress: net.IPv4(169, 254, 169, 254),
		// Use MMDS V1 - cloud-init's IMDSv2 implementation is not compatible with Firecracker's MMDS v2
		MmdsVersion:    firecracker.MMDSv1,
		ForwardSignals: []os.Signal{},
	}, firecracker.WithProcessRunner(machineCmd), firecracker.WithLogger(logrus.NewEntry(fcLogger)))

	if err != nil {
		_ = logFile.Close()
		_ = leaseCancel(ctx)
		return nil, fmt.Errorf("failed to create Firecracker machine: %w", err)
	}

	// Set MMDS metadata with runner configuration
	// Cloud-init expects: /version/meta-data/* and /version/user-data (as siblings)
	// Also add 2009-04-04 API version path for compatibility (cloud-init checks this before /latest/)
	if vmCfg.Metadata != nil {
		// Separate user-data from meta-data (cloud-init expects them as siblings, not nested)
		metaData := make(map[string]interface{})
		var userData interface{}
		for k, v := range vmCfg.Metadata {
			if k == "user-data" {
				userData = v
			} else {
				metaData[k] = v
			}
		}

		// Build the version data structure
		versionData := map[string]interface{}{
			"meta-data": metaData,
		}
		if userData != nil {
			versionData["user-data"] = userData
		}

		// Provide both /latest/ and /2009-04-04/ paths for cloud-init compatibility
		metadata := map[string]interface{}{
			"latest":     versionData,
			"2009-04-04": versionData,
		}
		machine.Handlers.FcInit = machine.Handlers.FcInit.Append(
			firecracker.NewSetMetadataHandler(metadata),
		)
	}

	// Start the VM
	if err := machine.Start(context.Background()); err != nil {
		_ = logFile.Close()
		_ = leaseCancel(ctx)
		return nil, fmt.Errorf("failed to start Firecracker VM: %w", err)
	}

	// Get IP address from network interface
	ipAddr := ""
	if len(machine.Cfg.NetworkInterfaces) > 0 {
		ni := machine.Cfg.NetworkInterfaces[0]
		if ni.StaticConfiguration != nil && ni.StaticConfiguration.IPConfiguration != nil {
			ipAddr = ni.StaticConfiguration.IPConfiguration.IPAddr.IP.String()
		}
	}

	vm := &VM{
		ID:          vmID,
		Name:        vmCfg.Name,
		IPAddress:   ipAddr,
		SocketPath:  socketPath,
		machine:     machine,
		leaseCancel: leaseCancel,
		logFile:     logFile,
	}

	m.vmsMu.Lock()
	m.vms[vmID] = vm
	m.vmsMu.Unlock()

	m.log.Infof("VM %s started successfully (IP: %s)", vmID, ipAddr)
	return vm, nil
}

// DestroyVM stops and cleans up a Firecracker VM.
// This function is idempotent - calling it on an already-destroyed VM returns nil.
func (m *Manager) DestroyVM(vmID string) error {
	m.vmsMu.Lock()
	vm, ok := m.vms[vmID]
	if !ok {
		m.vmsMu.Unlock()
		// VM already destroyed or never existed - this is fine during shutdown
		return nil
	}
	delete(m.vms, vmID)
	m.vmsMu.Unlock()

	m.log.Infof("Destroying VM %s", vmID)

	// Stop the VMM
	if vm.machine != nil {
		if err := vm.machine.StopVMM(); err != nil {
			m.log.Warnf("Failed to stop VMM for %s: %v", vmID, err)
		}

		// Wait for graceful shutdown with timeout
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = vm.machine.Wait(ctx)
		cancel()
	}

	// Clean up containerd lease
	if vm.leaseCancel != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := vm.leaseCancel(ctx); err != nil && !errdefs.IsNotFound(err) {
			m.log.Warnf("Failed to remove containerd lease for %s: %v", vmID, err)
		}
		cancel()
	}

	// Close log file
	if vm.logFile != nil {
		_ = vm.logFile.Close()
	}

	// Clean up socket file
	if vm.SocketPath != "" {
		_ = os.Remove(vm.SocketPath)
	}

	m.log.Infof("VM %s destroyed", vmID)
	return nil
}

// WaitForExit blocks until the VM exits or the context is cancelled.
func (m *Manager) WaitForExit(ctx context.Context, vmID string) error {
	m.vmsMu.RLock()
	vm, ok := m.vms[vmID]
	m.vmsMu.RUnlock()

	if !ok {
		return fmt.Errorf("VM %s not found", vmID)
	}

	if vm.machine == nil {
		return fmt.Errorf("VM %s has no machine instance", vmID)
	}

	// Wait for machine to exit
	return vm.machine.Wait(ctx)
}

// GetVM returns information about a specific VM.
func (m *Manager) GetVM(vmID string) (*VM, error) {
	m.vmsMu.RLock()
	defer m.vmsMu.RUnlock()

	vm, ok := m.vms[vmID]
	if !ok {
		return nil, fmt.Errorf("VM %s not found", vmID)
	}

	return vm, nil
}

// ListVMs returns all running VMs.
func (m *Manager) ListVMs() []*VM {
	m.vmsMu.RLock()
	defer m.vmsMu.RUnlock()

	vms := make([]*VM, 0, len(m.vms))
	for _, vm := range m.vms {
		vms = append(vms, vm)
	}

	return vms
}

// ensureImage pulls an image if not present and returns it.
func (m *Manager) ensureImage(ctx context.Context, ref string, poolName string) (containerd.Image, error) {
	m.containerdMu.Lock()
	defer m.containerdMu.Unlock()

	// Check if image already exists
	image, err := m.containerd.GetImage(ctx, ref)
	if err == nil {
		m.log.Debugf("Image %s already exists", ref)
		return image, nil
	}

	if !errdefs.IsNotFound(err) {
		return nil, fmt.Errorf("failed to check image: %w", err)
	}

	m.log.Infof("Pulling image %s", ref)
	start := time.Now()

	// Parse docker reference
	dockerRef, err := reference.ParseDockerRef(ref)
	if err != nil {
		return nil, fmt.Errorf("failed to parse image ref: %w", err)
	}

	// Create resolver for authentication
	refDomain := reference.Domain(dockerRef)
	resolver, err := dockerconfigresolver.New(ctx, refDomain)
	if err != nil {
		return nil, fmt.Errorf("failed to create docker config resolver: %w", err)
	}

	// Pull the image
	snapshotter := m.cfg.Containerd.Snapshotter
	if snapshotter == "" {
		snapshotter = DefaultSnapshotter
	}

	image, err = m.containerd.Pull(ctx, ref,
		containerd.WithPullUnpack,
		containerd.WithResolver(resolver),
		containerd.WithPullSnapshotter(snapshotter),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to pull image: %w", err)
	}

	m.log.Infof("Image %s pulled in %s", ref, time.Since(start))
	return image, nil
}

// createSnapshot creates a writable snapshot from an image.
func (m *Manager) createSnapshot(ctx context.Context, image containerd.Image, snapshotID string) ([]mount.Mount, error) {
	snapshotter := m.cfg.Containerd.Snapshotter
	if snapshotter == "" {
		snapshotter = DefaultSnapshotter
	}

	snapshotService := m.containerd.SnapshotService(snapshotter)

	// Check if snapshot already exists
	_, err := snapshotService.Stat(ctx, snapshotID)
	if err == nil {
		// Snapshot exists, get mounts
		return snapshotService.Mounts(ctx, snapshotID)
	}

	if !errdefs.IsNotFound(err) {
		return nil, fmt.Errorf("failed to check snapshot: %w", err)
	}

	// Unpack image if needed
	isUnpacked, err := image.IsUnpacked(ctx, snapshotter)
	if err != nil {
		return nil, fmt.Errorf("failed to check if image is unpacked: %w", err)
	}

	if !isUnpacked {
		m.log.Debugf("Unpacking image for snapshot %s", snapshotID)
		if err := image.Unpack(ctx, snapshotter); err != nil {
			return nil, fmt.Errorf("failed to unpack image: %w", err)
		}
	}

	// Get image rootfs chain ID
	imageContent, err := image.RootFS(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get image rootfs: %w", err)
	}

	// Prepare writable snapshot
	_, err = snapshotService.Prepare(ctx, snapshotID, identity.ChainID(imageContent).String())
	if err != nil {
		return nil, fmt.Errorf("failed to prepare snapshot: %w", err)
	}

	// Get mount points
	mounts, err := snapshotService.Mounts(ctx, snapshotID)
	if err != nil {
		return nil, fmt.Errorf("failed to get snapshot mounts: %w", err)
	}

	return mounts, nil
}

// getFirecrackerBinary returns the path to the firecracker binary.
// It first checks pool-specific config, then searches common locations.
func (m *Manager) getFirecrackerBinary(poolName string) string {
	// Check if pool has a configured binary path
	for _, pool := range m.cfg.Pools {
		if pool.Name == poolName && pool.Firecracker.BinaryPath != "" {
			return pool.Firecracker.BinaryPath
		}
	}

	// Check common locations
	paths := []string{
		"/usr/bin/firecracker",
		"/usr/local/bin/firecracker",
		"/opt/firecracker/firecracker",
	}

	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}

	// Default to expecting it in PATH
	return "firecracker"
}
