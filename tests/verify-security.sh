#!/usr/bin/env bash
#
# Security Verification Tests for Firecracker Runner Infrastructure
#
# Usage: ./verify-security.sh [--vm-ip <ip>] [--verbose]
#
# This script verifies the security hardening is working correctly:
# - Kernel hardening (sysctls)
# - Network isolation (VM-to-VM blocking, metadata blocking)
# - Storage security (encryption, secure deletion)
# - Jailer integration (process isolation)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

VERBOSE=false
VM_IP=""
TESTS_PASSED=0
TESTS_FAILED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --vm-ip)
      VM_IP="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

log() {
  echo -e "$1"
}

pass() {
  log "${GREEN}[PASS]${NC} $1"
  ((TESTS_PASSED++))
}

fail() {
  log "${RED}[FAIL]${NC} $1"
  ((TESTS_FAILED++))
}

warn() {
  log "${YELLOW}[WARN]${NC} $1"
}

info() {
  if $VERBOSE; then
    log "[INFO] $1"
  fi
}

# ============================================================================
# Host-side tests (run on the Firecracker host)
# ============================================================================

test_kernel_hardening() {
  log "\n=== Kernel Hardening Tests ==="

  # Test dmesg_restrict
  if [[ $(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null) == "1" ]]; then
    pass "kernel.dmesg_restrict = 1"
  else
    fail "kernel.dmesg_restrict is not set to 1"
  fi

  # Test kptr_restrict
  if [[ $(cat /proc/sys/kernel/kptr_restrict 2>/dev/null) == "2" ]]; then
    pass "kernel.kptr_restrict = 2"
  else
    fail "kernel.kptr_restrict is not set to 2"
  fi

  # Test sysrq
  if [[ $(cat /proc/sys/kernel/sysrq 2>/dev/null) == "0" ]]; then
    pass "kernel.sysrq = 0 (disabled)"
  else
    fail "kernel.sysrq is not disabled"
  fi

  # Test rp_filter
  if [[ $(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null) == "1" ]]; then
    pass "net.ipv4.conf.all.rp_filter = 1"
  else
    fail "net.ipv4.conf.all.rp_filter is not set to 1"
  fi

  # Test accept_redirects
  if [[ $(cat /proc/sys/net/ipv4/conf/all/accept_redirects 2>/dev/null) == "0" ]]; then
    pass "net.ipv4.conf.all.accept_redirects = 0"
  else
    fail "net.ipv4.conf.all.accept_redirects is not disabled"
  fi

  # Test tcp_syncookies
  if [[ $(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null) == "1" ]]; then
    pass "net.ipv4.tcp_syncookies = 1"
  else
    fail "net.ipv4.tcp_syncookies is not enabled"
  fi
}

test_smt_status() {
  log "\n=== SMT/Hyperthreading Status ==="

  SMT_FILE="/sys/devices/system/cpu/smt/active"
  if [[ -f "$SMT_FILE" ]]; then
    SMT_ACTIVE=$(cat "$SMT_FILE")
    if [[ "$SMT_ACTIVE" == "0" ]]; then
      pass "SMT is disabled"
    else
      warn "SMT is enabled (set disableHyperthreading = true for maximum security)"
    fi
  else
    warn "Cannot determine SMT status (file not found)"
  fi
}

test_nftables_rules() {
  log "\n=== nftables Network Isolation ==="

  # Check if nftables is active
  if ! command -v nft &>/dev/null; then
    fail "nft command not found"
    return
  fi

  # Check for fireactions_isolation table
  if nft list table inet fireactions_isolation &>/dev/null; then
    pass "fireactions_isolation nftables table exists"

    # Check for VM-to-VM blocking rule
    if nft list table inet fireactions_isolation | grep -q "Block VM-to-VM"; then
      pass "VM-to-VM blocking rule present"
    else
      fail "VM-to-VM blocking rule not found"
    fi

    # Check for metadata blocking rule
    if nft list table inet fireactions_isolation | grep -q "169.254.169.254"; then
      pass "Cloud metadata blocking rule present"
    else
      fail "Cloud metadata blocking rule not found"
    fi

    # Check for rate limiting
    if nft list table inet fireactions_isolation | grep -q "limit rate"; then
      pass "Rate limiting rule present"
    else
      warn "Rate limiting rule not found (optional)"
    fi
  else
    fail "fireactions_isolation nftables table not found"
  fi
}

test_jailer_status() {
  log "\n=== Jailer Integration ==="

  # Check if any firecracker processes are running under jailer
  if pgrep -f "jailer.*firecracker" &>/dev/null; then
    pass "Firecracker processes running under jailer"
  else
    # Check if firecracker is running at all
    if pgrep firecracker &>/dev/null; then
      warn "Firecracker running without jailer (jailer.enable = false)"
    else
      info "No Firecracker processes currently running"
    fi
  fi

  # Check chroot directory
  if [[ -d "/srv/jailer" ]]; then
    pass "Jailer chroot base directory exists"
  else
    warn "Jailer chroot directory not found (/srv/jailer)"
  fi

  # Check UID pool state
  if [[ -d "/var/lib/fireactions/jailer/uid-pool" ]]; then
    pass "UID pool state directory exists"
  else
    warn "UID pool state directory not found"
  fi
}

test_storage_security() {
  log "\n=== Storage Security ==="

  # Check if LUKS is in use
  if dmsetup status containerd-data-crypt &>/dev/null; then
    pass "Storage pool is LUKS encrypted"
  else
    warn "Storage pool is not encrypted (encryption.enable = false)"
  fi

  # Check containerd pool
  if dmsetup status containerd-pool &>/dev/null; then
    pass "containerd-pool device mapper exists"

    # Check for discard support
    if dmsetup table containerd-pool | grep -q "skip_block_zeroing"; then
      pass "Thin pool configured with efficient block handling"
    fi
  else
    fail "containerd-pool not found"
  fi

  # Check tmpfs secrets mount
  if mount | grep -q "/run/fireactions/secrets.*tmpfs"; then
    pass "Tmpfs secrets mount active"
  else
    warn "Tmpfs secrets mount not found"
  fi
}

test_systemd_hardening() {
  log "\n=== Systemd Service Hardening ==="

  SERVICE="fireactions.service"

  if ! systemctl is-active "$SERVICE" &>/dev/null; then
    warn "fireactions service not running, skipping hardening check"
    return
  fi

  # Check for security properties
  PROPS=$(systemctl show "$SERVICE" 2>/dev/null)

  if echo "$PROPS" | grep -q "ProtectSystem=strict"; then
    pass "ProtectSystem=strict"
  else
    fail "ProtectSystem not set to strict"
  fi

  if echo "$PROPS" | grep -q "ProtectHome=yes"; then
    pass "ProtectHome=yes"
  else
    fail "ProtectHome not enabled"
  fi

  if echo "$PROPS" | grep -q "PrivateTmp=yes"; then
    pass "PrivateTmp=yes"
  else
    fail "PrivateTmp not enabled"
  fi
}

# ============================================================================
# VM-side tests (run from inside a VM or via SSH)
# ============================================================================

test_vm_isolation() {
  if [[ -z "$VM_IP" ]]; then
    warn "Skipping VM isolation tests (use --vm-ip to specify VM address)"
    return
  fi

  log "\n=== VM Isolation Tests (from $VM_IP) ==="

  # Test cloud metadata blocking
  log "Testing cloud metadata access..."
  if ssh -o ConnectTimeout=5 "$VM_IP" "curl -sf --connect-timeout 2 http://169.254.169.254/" 2>/dev/null; then
    fail "VM can access cloud metadata (should be blocked)"
  else
    pass "Cloud metadata access blocked"
  fi

  # Note: VM-to-VM test requires a second VM IP
  warn "VM-to-VM isolation test requires manual verification with multiple VMs"
}

# ============================================================================
# Main
# ============================================================================

main() {
  log "=========================================="
  log " Firecracker Security Verification Tests"
  log "=========================================="

  test_kernel_hardening
  test_smt_status
  test_nftables_rules
  test_jailer_status
  test_storage_security
  test_systemd_hardening
  test_vm_isolation

  log "\n=========================================="
  log " Summary"
  log "=========================================="
  log "${GREEN}Passed: $TESTS_PASSED${NC}"
  log "${RED}Failed: $TESTS_FAILED${NC}"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    log "\n${YELLOW}Some tests failed. Review the output above for details.${NC}"
    exit 1
  else
    log "\n${GREEN}All tests passed!${NC}"
    exit 0
  fi
}

main "$@"
