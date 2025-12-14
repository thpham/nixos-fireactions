# Firecracker jailer integration for enhanced process isolation
#
# The jailer provides multiple security layers:
# - Unique UID/GID per microVM (no shared credentials)
# - Chroot environment with minimal filesystem
# - Network namespace isolation
# - Seccomp filtering
# - Cgroup resource limits
#
# Implementation: Wrapper script intercepts firecracker invocations
# from fireactions daemon and invokes jailer instead.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions.security;
  jailerCfg = cfg.jailer;
  fireactionsCfg = config.services.fireactions;

  # UID pool management script
  uidPoolScript = pkgs.writeScript "uid-pool-manage" ''
    #!${pkgs.python3}/bin/python3
    """
    UID/GID pool management for Firecracker jailer.

    Manages allocation and deallocation of unique UIDs for each microVM.
    Uses file-based locking for atomic operations.
    """

    import json
    import os
    import sys
    import fcntl
    import time
    import subprocess
    from pathlib import Path

    POOL_DIR = Path("${jailerCfg.stateDir}/uid-pool")
    ALLOCATIONS_FILE = POOL_DIR / "allocations.json"
    LOCK_FILE = POOL_DIR / ".lock"
    UID_START = ${toString jailerCfg.uidRangeStart}
    UID_END = ${toString jailerCfg.uidRangeEnd}
    MAX_AGE_HOURS = 24

    def ensure_dirs():
        POOL_DIR.mkdir(parents=True, exist_ok=True)
        LOCK_FILE.touch(exist_ok=True)

    def load_allocations():
        if ALLOCATIONS_FILE.exists():
            with open(ALLOCATIONS_FILE) as f:
                return json.load(f)
        return {}

    def save_allocations(allocations):
        with open(ALLOCATIONS_FILE, 'w') as f:
            json.dump(allocations, f, indent=2)

    def is_process_running(uid):
        """Check if any process is running with this UID."""
        try:
            result = subprocess.run(
                ["pgrep", "-u", str(uid)],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
        except:
            return False

    def allocate(vm_id):
        """Allocate a UID for the given VM ID."""
        ensure_dirs()

        with open(LOCK_FILE, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)

            allocations = load_allocations()

            # Check if VM already has allocation
            if vm_id in allocations:
                uid = allocations[vm_id]["uid"]
                allocations[vm_id]["last_seen"] = time.time()
                save_allocations(allocations)
                print(uid)
                return 0

            # Find next available UID
            used_uids = {a["uid"] for a in allocations.values()}
            for uid in range(UID_START, UID_END + 1):
                if uid not in used_uids:
                    allocations[vm_id] = {
                        "uid": uid,
                        "allocated_at": time.time(),
                        "last_seen": time.time()
                    }
                    save_allocations(allocations)
                    print(uid)
                    return 0

            print("ERROR: UID pool exhausted", file=sys.stderr)
            return 1

    def release(vm_id):
        """Release UID allocation for the given VM ID."""
        ensure_dirs()

        with open(LOCK_FILE, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)

            allocations = load_allocations()
            if vm_id in allocations:
                del allocations[vm_id]
                save_allocations(allocations)
                print(f"Released UID for {vm_id}")
            return 0

    def cleanup():
        """Remove stale allocations (old and not running)."""
        ensure_dirs()

        with open(LOCK_FILE, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)

            allocations = load_allocations()
            now = time.time()
            max_age = MAX_AGE_HOURS * 3600
            to_remove = []

            for vm_id, info in allocations.items():
                age = now - info.get("last_seen", info["allocated_at"])
                if age > max_age and not is_process_running(info["uid"]):
                    to_remove.append(vm_id)
                    print(f"Cleaning up stale allocation: {vm_id} (uid={info['uid']}, age={age/3600:.1f}h)")

            for vm_id in to_remove:
                del allocations[vm_id]

            if to_remove:
                save_allocations(allocations)
                print(f"Cleaned up {len(to_remove)} stale allocations")
            else:
                print("No stale allocations found")

            return 0

    def status():
        """Show current allocations."""
        ensure_dirs()
        allocations = load_allocations()

        print(f"UID Pool Status:")
        print(f"  Range: {UID_START} - {UID_END}")
        print(f"  Allocated: {len(allocations)}")
        print(f"  Available: {UID_END - UID_START + 1 - len(allocations)}")
        print()

        if allocations:
            print("Active Allocations:")
            for vm_id, info in sorted(allocations.items(), key=lambda x: x[1]["uid"]):
                age = (time.time() - info.get("last_seen", info["allocated_at"])) / 3600
                running = "running" if is_process_running(info["uid"]) else "stopped"
                print(f"  {vm_id}: uid={info['uid']}, age={age:.1f}h, status={running}")

        return 0

    if __name__ == "__main__":
        if len(sys.argv) < 2:
            print("Usage: uid-pool-manage <allocate|release|cleanup|status> [vm_id]")
            sys.exit(1)

        cmd = sys.argv[1]

        if cmd == "allocate" and len(sys.argv) >= 3:
            sys.exit(allocate(sys.argv[2]))
        elif cmd == "release" and len(sys.argv) >= 3:
            sys.exit(release(sys.argv[2]))
        elif cmd == "cleanup":
            sys.exit(cleanup())
        elif cmd == "status":
            sys.exit(status())
        else:
            print(f"Unknown command: {cmd}")
            sys.exit(1)
  '';

  # Jailer wrapper script that intercepts firecracker invocations
  jailerWrapper = pkgs.writeShellScript "firecracker-jailer-wrapper" ''
    #!/usr/bin/env bash
    #
    # Firecracker Jailer Wrapper
    #
    # Intercepts firecracker invocations from fireactions daemon and
    # wraps them with the jailer for enhanced security isolation.
    #
    set -euo pipefail

    # Configuration
    CHROOT_BASE="${jailerCfg.chrootBaseDir}"
    UID_POOL_SCRIPT="${uidPoolScript}"
    JAILER_BIN="${pkgs.firecracker}/bin/jailer"
    FIRECRACKER_BIN="${pkgs.firecracker}/bin/firecracker"

    # Parse command line to extract VM identifier
    # fireactions calls: firecracker --api-sock /path/to/socket.sock ...
    SOCKET_PATH=""
    CONFIG_FILE=""
    ORIGINAL_ARGS=()

    while [[ $# -gt 0 ]]; do
      case $1 in
        --api-sock)
          SOCKET_PATH="$2"
          # Don't pass to jailer - it manages its own socket
          shift 2
          ;;
        --config-file)
          CONFIG_FILE="$2"
          ORIGINAL_ARGS+=("$1" "$2")
          shift 2
          ;;
        *)
          ORIGINAL_ARGS+=("$1")
          shift
          ;;
      esac
    done

    # Generate VM ID from socket path
    if [ -z "$SOCKET_PATH" ]; then
      echo "ERROR: No --api-sock provided, cannot determine VM ID" >&2
      exit 1
    fi

    # Create deterministic VM ID from socket path
    VM_ID="fc-$(echo "$SOCKET_PATH" | md5sum | cut -c1-12)"

    # Allocate UID from pool
    UID_GID=$("${pkgs.python3}/bin/python3" "$UID_POOL_SCRIPT" allocate "$VM_ID")
    if [ -z "$UID_GID" ]; then
      echo "ERROR: Failed to allocate UID for $VM_ID" >&2
      exit 1
    fi

    # Setup cleanup trap to release UID allocation
    cleanup() {
      "${pkgs.python3}/bin/python3" "$UID_POOL_SCRIPT" release "$VM_ID" || true
    }
    trap cleanup EXIT

    # Ensure chroot base exists
    mkdir -p "$CHROOT_BASE"

    # Check if network namespace exists (created by CNI)
    NETNS_PATH="/var/run/netns/$VM_ID"
    NETNS_ARG=""
    if [ -f "$NETNS_PATH" ] || [ -L "$NETNS_PATH" ]; then
      NETNS_ARG="--netns $NETNS_PATH"
    fi

    # Log jailer invocation
    echo "Starting jailer for VM: $VM_ID (uid=$UID_GID)"

    # Socket paths:
    # - SOCKET_PATH: where fireactions expects the socket (e.g., /var/lib/fireactions/pools/default/runner-xxx.sock)
    # - Jailer creates socket inside chroot at: $CHROOT_BASE/firecracker/$VM_ID/root/run/firecracker.socket
    # We need to symlink so fireactions can find it
    JAILER_SOCKET="$CHROOT_BASE/firecracker/$VM_ID/root/run/firecracker.socket"

    # Create the run directory inside chroot (jailer doesn't create it)
    mkdir -p "$CHROOT_BASE/firecracker/$VM_ID/root/run"
    chown "$UID_GID:$UID_GID" "$CHROOT_BASE/firecracker/$VM_ID/root/run"

    # Create symlink from expected path to actual jailer socket location
    # Remove any stale socket/symlink first
    rm -f "$SOCKET_PATH"
    ln -sf "$JAILER_SOCKET" "$SOCKET_PATH"

    # Invoke jailer
    # Note: --api-sock path is relative to chroot root (firecracker sees / as $CHROOT_BASE/.../root/)
    exec "$JAILER_BIN" \
      --id "$VM_ID" \
      --exec-file "$FIRECRACKER_BIN" \
      --uid "$UID_GID" \
      --gid "$UID_GID" \
      --chroot-base-dir "$CHROOT_BASE" \
      $NETNS_ARG \
      ${
        lib.optionalString (jailerCfg.cgroupVersion != null) "--cgroup-version ${jailerCfg.cgroupVersion}"
      } \
      ${lib.optionalString jailerCfg.daemonize "--daemonize"} \
      -- \
      --api-sock /run/firecracker.socket \
      "''${ORIGINAL_ARGS[@]}"
  '';

  # Package the wrapper as a derivation
  jailerWrapperPackage = pkgs.runCommand "firecracker-jailer-wrapper" { } ''
    mkdir -p $out/bin
    cp ${jailerWrapper} $out/bin/firecracker
    chmod +x $out/bin/firecracker
  '';

in
{
  options.services.fireactions.security.jailer = {
    enable = lib.mkEnableOption ''
      Firecracker jailer integration.

      Wraps all Firecracker invocations with the jailer for:
      - Unique UID/GID per VM (process isolation)
      - Chroot environment (filesystem isolation)
      - Network namespace (already handled by CNI)
      - Optional seccomp filtering

      Note: This intercepts the firecracker binary path and replaces
      it with a wrapper that invokes the jailer.
    '';

    uidRangeStart = lib.mkOption {
      type = lib.types.int;
      default = 100000;
      description = ''
        Start of the UID range for VM isolation.

        Each VM gets a unique UID from this pool.
        Default uses the subordinate UID range (100000-165535).
      '';
    };

    uidRangeEnd = lib.mkOption {
      type = lib.types.int;
      default = 165535;
      description = ''
        End of the UID range for VM isolation.

        Pool size = uidRangeEnd - uidRangeStart + 1
        Default provides ~65K unique UIDs.
      '';
    };

    chrootBaseDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/jailer";
      description = ''
        Base directory for jailer chroot environments.

        Each VM gets a chroot at: <chrootBaseDir>/firecracker/<vm-id>/root/
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fireactions/jailer";
      description = ''
        Directory for jailer state (UID pool allocations, etc.)
      '';
    };

    cgroupVersion = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "1"
          "2"
        ]
      );
      default = "2";
      description = ''
        Cgroup version to use for resource isolation.

        - "2": cgroup v2 (unified, recommended)
        - "1": cgroup v1 (legacy)
        - null: let jailer auto-detect
      '';
    };

    daemonize = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run jailed Firecracker as a daemon.

        When enabled, jailer forks and the parent exits immediately.
        Usually not needed as fireactions manages the process lifecycle.
      '';
    };

    cleanupInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = ''
        How often to clean up orphaned UID allocations and chroot directories.
      '';
    };

    circuitBreaker = {
      maxFailures = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = ''
          Maximum number of consecutive failures before stopping fireactions.

          This prevents fast-fail loops from registering hundreds of orphaned
          GitHub runners. When triggered, fireactions service is stopped and
          must be manually restarted after investigating the issue.
        '';
      };

      windowSeconds = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = ''
          Time window in seconds for counting failures.

          If maxFailures occur within this window, the circuit breaker trips.
          After the window passes without failures, the counter resets.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && jailerCfg.enable) {
    # Create required directories
    systemd.tmpfiles.rules = [
      "d ${jailerCfg.chrootBaseDir} 0755 root root -"
      "d ${jailerCfg.stateDir} 0750 root root -"
      "d ${jailerCfg.stateDir}/uid-pool 0750 root root -"
    ];

    # Circuit breaker log watcher - monitors fireactions logs for rapid failures
    # and stops the service before it creates too many orphaned runners
    systemd.services.fireactions-circuit-breaker = {
      description = "Circuit breaker for fireactions - stops service on rapid failures";
      after = [ "fireactions.service" ];
      bindsTo = [ "fireactions.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";
      };

      script = ''
        #!/usr/bin/env bash
        set -euo pipefail

        MAX_FAILURES=${toString jailerCfg.circuitBreaker.maxFailures}
        WINDOW_SECONDS=${toString jailerCfg.circuitBreaker.windowSeconds}
        STATE_FILE="${jailerCfg.stateDir}/circuit_breaker_state"

        echo "Circuit breaker started: max $MAX_FAILURES failures in $WINDOW_SECONDS seconds"

        # Initialize state
        mkdir -p "$(dirname "$STATE_FILE")"
        echo "0" > "$STATE_FILE"

        # Array to track failure timestamps (using file since bash arrays don't persist)
        FAILURES_FILE="${jailerCfg.stateDir}/failure_timestamps"
        : > "$FAILURES_FILE"

        count_recent_failures() {
          local now=$(date +%s)
          local cutoff=$((now - WINDOW_SECONDS))
          local count=0

          if [ -f "$FAILURES_FILE" ]; then
            while read -r ts; do
              if [ -n "$ts" ] && [ "$ts" -gt "$cutoff" ] 2>/dev/null; then
                count=$((count + 1))
              fi
            done < "$FAILURES_FILE"
          fi

          echo "$count"
        }

        add_failure() {
          local now=$(date +%s)
          echo "$now" >> "$FAILURES_FILE"

          # Prune old entries
          local cutoff=$((now - WINDOW_SECONDS))
          local temp=$(mktemp)
          while read -r ts; do
            if [ -n "$ts" ] && [ "$ts" -gt "$cutoff" ] 2>/dev/null; then
              echo "$ts"
            fi
          done < "$FAILURES_FILE" > "$temp"
          mv "$temp" "$FAILURES_FILE"
        }

        # Monitor fireactions logs for failure pattern
        # Use --since "now" to only see NEW entries, not historical failures
        ${pkgs.systemd}/bin/journalctl -u fireactions -f --since "now" -o cat | while read -r line; do
          if echo "$line" | grep -q "Failed to scale pool"; then
            add_failure
            count=$(count_recent_failures)
            echo "Failure detected: $count/$MAX_FAILURES in last $WINDOW_SECONDS seconds"

            if [ "$count" -ge "$MAX_FAILURES" ]; then
              echo "========================================"
              echo "CIRCUIT BREAKER TRIGGERED!"
              echo "$count failures in $WINDOW_SECONDS seconds"
              echo "Stopping fireactions to prevent orphaned runners"
              echo "========================================"

              # Stop fireactions
              ${pkgs.systemd}/bin/systemctl stop fireactions.service

              # Mark circuit breaker as tripped
              echo "tripped:$(date +%s)" > "$STATE_FILE"

              echo "Fireactions stopped. To restart after fixing the issue:"
              echo "  systemctl start fireactions"
              exit 0
            fi
          fi
        done
      '';
    };

    # Override firecracker binary path to use our wrapper
    # This is done by modifying the PATH for fireactions service
    systemd.services.fireactions = {
      path = lib.mkBefore [ jailerWrapperPackage ];

      # Additional capabilities needed for jailer
      serviceConfig = {
        AmbientCapabilities = lib.mkAfter [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_MKNOD"
          "CAP_CHOWN"
        ];
        CapabilityBoundingSet = lib.mkAfter [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_MKNOD"
          "CAP_CHOWN"
        ];

        # Additional paths for jailer
        ReadWritePaths = lib.mkAfter [
          jailerCfg.chrootBaseDir
          jailerCfg.stateDir
        ];
      };
    };

    # UID pool cleanup service
    systemd.services.fireactions-uid-pool-cleanup = {
      description = "Cleanup orphaned Firecracker jailer UID allocations";
      after = [ "fireactions.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${uidPoolScript} cleanup";
      };
    };

    # Cleanup timer
    systemd.timers.fireactions-uid-pool-cleanup = {
      description = "Periodic cleanup of orphaned jailer UID allocations";
      wantedBy = [ "timers.target" ];
      after = [ "fireactions.service" ];

      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = jailerCfg.cleanupInterval;
        RandomizedDelaySec = "30s";
      };
    };

    # Chroot directory cleanup service
    systemd.services.fireactions-chroot-cleanup = {
      description = "Cleanup orphaned Firecracker jailer chroot directories";
      after = [ "fireactions-uid-pool-cleanup.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        set -euo pipefail

        CHROOT_BASE="${jailerCfg.chrootBaseDir}/firecracker"
        ALLOCATIONS_FILE="${jailerCfg.stateDir}/uid-pool/allocations.json"

        if [ ! -d "$CHROOT_BASE" ]; then
          echo "No chroot directories to clean"
          exit 0
        fi

        # Get list of currently allocated VM IDs
        ALLOCATED_VMS=""
        if [ -f "$ALLOCATIONS_FILE" ]; then
          ALLOCATED_VMS=$(${pkgs.jq}/bin/jq -r 'keys[]' "$ALLOCATIONS_FILE" 2>/dev/null || true)
        fi

        # Clean up orphaned chroot directories
        for vm_dir in "$CHROOT_BASE"/*; do
          if [ -d "$vm_dir" ]; then
            VM_ID=$(basename "$vm_dir")

            # Check if VM is still allocated
            if ! echo "$ALLOCATED_VMS" | grep -q "^$VM_ID$"; then
              echo "Cleaning up orphaned chroot: $VM_ID"
              rm -rf "$vm_dir"
            fi
          fi
        done

        echo "Chroot cleanup completed"
      '';
    };

    # Run chroot cleanup after UID cleanup
    systemd.timers.fireactions-chroot-cleanup = {
      description = "Periodic cleanup of orphaned jailer chroot directories";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = jailerCfg.cleanupInterval;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
