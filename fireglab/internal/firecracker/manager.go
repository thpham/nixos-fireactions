// Package firecracker provides Firecracker VM management for fireglab.
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
	"github.com/containerd/containerd/namespaces"
	"github.com/containerd/errdefs"
	"github.com/containerd/nerdctl/pkg/imgutil/dockerconfigresolver"
	"github.com/distribution/reference"
	"github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/opencontainers/image-spec/identity"
	"github.com/sirupsen/logrus"
	"github.com/thpham/fireglab/internal/config"
	"github.com/thpham/fireglab/internal/stringid"
)

const (
	// DefaultSnapshotter is the default containerd snapshotter for rootfs.
	DefaultSnapshotter = "devmapper"
	// DefaultNetworkName is the default CNI network name.
	DefaultNetworkName = "fireglab"
	// DefaultPoolDir is the base directory for pool data.
	DefaultPoolDir = "/var/lib/fireglab/pools"
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
	PoolName    string
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
func (m *Manager) cleanupStaleResources() {
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

		if filepath.Ext(file.Name()) != ".sock" {
			continue
		}

		socketPath := filepath.Join(poolDir, file.Name())

		if m.isSocketActive(socketPath) {
			m.log.Debugf("Socket %s is still active, skipping cleanup", socketPath)
			continue
		}

		m.log.Infof("Removing stale socket: %s", socketPath)
		if err := os.Remove(socketPath); err != nil {
			m.log.Warnf("Failed to remove stale socket %s: %v", socketPath, err)
		}

		logPath := socketPath[:len(socketPath)-5] + ".log"
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
	conn, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
	if err != nil {
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
	vmID := fmt.Sprintf("%s-%s", vmCfg.ID, stringid.New())

	m.log.Infof("Creating VM %s with %d MiB RAM and %d vCPUs", vmID, vmCfg.MemSizeMib, vmCfg.VcpuCount)

	if err := m.EnsurePoolDir(vmCfg.PoolName); err != nil {
		return nil, err
	}
	poolDir := m.GetPoolDir(vmCfg.PoolName)

	nsCtx := namespaces.WithNamespace(ctx, vmCfg.PoolName)

	image, err := m.ensureImage(nsCtx, vmCfg.Image, vmCfg.PoolName)
	if err != nil {
		return nil, fmt.Errorf("failed to ensure image: %w", err)
	}

	leaseID := fmt.Sprintf("fireglab/pools/%s/%s", vmCfg.PoolName, vmID)
	leaseCtx, leaseCancel, err := m.containerd.WithLease(nsCtx, leases.WithID(leaseID))
	if err != nil {
		return nil, fmt.Errorf("failed to create containerd lease: %w", err)
	}

	snapshotMounts, err := m.createSnapshot(leaseCtx, image, vmID)
	if err != nil {
		_ = leaseCancel(nsCtx)
		return nil, fmt.Errorf("failed to create snapshot: %w", err)
	}

	logFilePath := filepath.Join(poolDir, fmt.Sprintf("%s.log", vmID))
	logFile, err := os.Create(logFilePath)
	if err != nil {
		_ = leaseCancel(nsCtx)
		return nil, fmt.Errorf("failed to create log file: %w", err)
	}

	socketPath := filepath.Join(poolDir, fmt.Sprintf("%s.sock", vmID))
	firecrackerBin := m.getFirecrackerBinary(vmCfg.PoolName)

	machineCmd := firecracker.VMCommandBuilder{}.
		WithSocketPath(socketPath).
		WithStderr(logFile).
		WithStdout(logFile).
		WithBin(firecrackerBin).
		Build(context.Background())

	fcLogger := logrus.New()
	fcLogger.SetLevel(logrus.WarnLevel)
	fcLogger.SetOutput(io.Discard)

	kernelPath := vmCfg.KernelPath
	if kernelPath == "" {
		kernelPath = m.cfg.Pools[0].Firecracker.KernelPath
	}

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
		MmdsAddress:    net.IPv4(169, 254, 169, 254),
		MmdsVersion:    firecracker.MMDSv1,
		ForwardSignals: []os.Signal{},
	}, firecracker.WithProcessRunner(machineCmd), firecracker.WithLogger(logrus.NewEntry(fcLogger)))

	if err != nil {
		_ = logFile.Close()
		_ = leaseCancel(nsCtx)
		return nil, fmt.Errorf("failed to create Firecracker machine: %w", err)
	}

	// Set MMDS metadata with runner configuration
	if vmCfg.Metadata != nil {
		metaData := make(map[string]interface{})
		var userData interface{}
		for k, v := range vmCfg.Metadata {
			if k == "user-data" {
				userData = v
			} else {
				metaData[k] = v
			}
		}

		versionData := map[string]interface{}{
			"meta-data": metaData,
		}
		if userData != nil {
			versionData["user-data"] = userData
		}

		metadata := map[string]interface{}{
			"latest":     versionData,
			"2009-04-04": versionData,
		}
		machine.Handlers.FcInit = machine.Handlers.FcInit.Append(
			firecracker.NewSetMetadataHandler(metadata),
		)
	}

	if err := machine.Start(context.Background()); err != nil {
		_ = logFile.Close()
		_ = leaseCancel(nsCtx)
		return nil, fmt.Errorf("failed to start Firecracker VM: %w", err)
	}

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
		PoolName:    vmCfg.PoolName,
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
func (m *Manager) DestroyVM(vmID string) error {
	m.vmsMu.Lock()
	vm, ok := m.vms[vmID]
	if !ok {
		m.vmsMu.Unlock()
		return nil
	}
	delete(m.vms, vmID)
	m.vmsMu.Unlock()

	m.log.Infof("Destroying VM %s", vmID)

	if vm.machine != nil {
		if err := vm.machine.StopVMM(); err != nil {
			m.log.Warnf("Failed to stop VMM for %s: %v", vmID, err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = vm.machine.Wait(ctx)
		cancel()
	}

	if vm.leaseCancel != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		nsCtx := namespaces.WithNamespace(ctx, vm.PoolName)
		if err := vm.leaseCancel(nsCtx); err != nil && !errdefs.IsNotFound(err) {
			m.log.Warnf("Failed to remove containerd lease for %s: %v", vmID, err)
		}
		cancel()
	}

	if vm.logFile != nil {
		_ = vm.logFile.Close()
	}

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

	nsCtx := namespaces.WithNamespace(ctx, poolName)

	image, err := m.containerd.GetImage(nsCtx, ref)
	if err == nil {
		m.log.Debugf("Image %s already exists in namespace %s", ref, poolName)
		return image, nil
	}

	if !errdefs.IsNotFound(err) {
		return nil, fmt.Errorf("failed to check image: %w", err)
	}

	m.log.Infof("Pulling image %s into namespace %s", ref, poolName)
	start := time.Now()

	dockerRef, err := reference.ParseDockerRef(ref)
	if err != nil {
		return nil, fmt.Errorf("failed to parse image ref: %w", err)
	}

	refDomain := reference.Domain(dockerRef)
	resolver, err := dockerconfigresolver.New(ctx, refDomain)
	if err != nil {
		return nil, fmt.Errorf("failed to create docker config resolver: %w", err)
	}

	snapshotter := m.cfg.Containerd.Snapshotter
	if snapshotter == "" {
		snapshotter = DefaultSnapshotter
	}

	image, err = m.containerd.Pull(nsCtx, ref,
		containerd.WithPullUnpack,
		containerd.WithResolver(resolver),
		containerd.WithPullSnapshotter(snapshotter),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to pull image: %w", err)
	}

	m.log.Infof("Image %s pulled into namespace %s in %s", ref, poolName, time.Since(start))
	return image, nil
}

// createSnapshot creates a writable snapshot from an image.
func (m *Manager) createSnapshot(ctx context.Context, image containerd.Image, snapshotID string) ([]mount.Mount, error) {
	snapshotter := m.cfg.Containerd.Snapshotter
	if snapshotter == "" {
		snapshotter = DefaultSnapshotter
	}

	snapshotService := m.containerd.SnapshotService(snapshotter)

	_, err := snapshotService.Stat(ctx, snapshotID)
	if err == nil {
		return snapshotService.Mounts(ctx, snapshotID)
	}

	if !errdefs.IsNotFound(err) {
		return nil, fmt.Errorf("failed to check snapshot: %w", err)
	}

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

	imageContent, err := image.RootFS(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get image rootfs: %w", err)
	}

	_, err = snapshotService.Prepare(ctx, snapshotID, identity.ChainID(imageContent).String())
	if err != nil {
		return nil, fmt.Errorf("failed to prepare snapshot: %w", err)
	}

	mounts, err := snapshotService.Mounts(ctx, snapshotID)
	if err != nil {
		return nil, fmt.Errorf("failed to get snapshot mounts: %w", err)
	}

	return mounts, nil
}

// getFirecrackerBinary returns the path to the firecracker binary.
func (m *Manager) getFirecrackerBinary(poolName string) string {
	for _, pool := range m.cfg.Pools {
		if pool.Name == poolName && pool.Firecracker.BinaryPath != "" {
			return pool.Firecracker.BinaryPath
		}
	}

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

	return "firecracker"
}
