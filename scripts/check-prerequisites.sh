#!/usr/bin/env bash
#
# Prerequisites Check Script for nixos-fireactions
#
# Usage:
#   ./scripts/check-prerequisites.sh                    # Check local environment
#   ./scripts/check-prerequisites.sh --remote <ip>      # Check remote server
#   ./scripts/check-prerequisites.sh --all <ip>         # Check both
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Counters
PASS=0
FAIL=0
WARN=0

# Print functions
print_header() {
    echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_check() {
    echo -ne "  Checking: $1... "
}

print_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS++))
}

print_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL++))
}

print_warn() {
    echo -e "${YELLOW}!${NC} $1"
    ((WARN++))
}

print_info() {
    echo -e "    ${BLUE}→${NC} $1"
}

# Check functions
check_command() {
    local cmd=$1
    local name=${2:-$1}
    print_check "$name"
    if command -v "$cmd" &>/dev/null; then
        local version
        version=$("$cmd" --version 2>/dev/null | head -n1 || echo "installed")
        print_pass "$version"
        return 0
    else
        print_fail "not found"
        return 1
    fi
}

check_nix() {
    print_header "Nix Installation"

    print_check "Nix"
    if command -v nix &>/dev/null; then
        local version
        version=$(nix --version 2>/dev/null)
        print_pass "$version"
    else
        print_fail "Nix not found"
        print_info "Install from: https://nixos.org/download"
        return 1
    fi

    print_check "Flakes enabled"
    if nix flake --help &>/dev/null 2>&1; then
        print_pass "enabled"
    else
        print_fail "not enabled"
        print_info "Add to ~/.config/nix/nix.conf:"
        print_info "  experimental-features = nix-command flakes"
        return 1
    fi

    print_check "Nix flake can fetch"
    if timeout 30 nix flake metadata github:thpham/nixos-fireactions &>/dev/null 2>&1; then
        print_pass "network access OK"
    else
        print_warn "could not fetch flake (network issue?)"
    fi
}

check_tools() {
    print_header "Required Tools"

    check_command "git" "Git"
    check_command "ssh" "SSH client"
    check_command "ssh-keygen" "ssh-keygen"

    print_check "sops"
    if command -v sops &>/dev/null; then
        print_pass "$(sops --version 2>/dev/null | head -n1)"
    else
        print_warn "not found (install with: nix profile install nixpkgs#sops)"
    fi

    print_check "age"
    if command -v age &>/dev/null; then
        print_pass "$(age --version 2>/dev/null)"
    else
        print_warn "not found (install with: nix profile install nixpkgs#age)"
    fi

    print_check "ssh-to-age"
    if command -v ssh-to-age &>/dev/null; then
        print_pass "installed"
    else
        print_warn "not found (install with: nix profile install nixpkgs#ssh-to-age)"
    fi

    print_check "colmena"
    if command -v colmena &>/dev/null; then
        print_pass "$(colmena --version 2>/dev/null)"
    else
        print_warn "not found (available in 'nix develop')"
    fi
}

check_age_key() {
    print_header "Age Key Configuration"

    local key_file="$HOME/.config/sops/age/keys.txt"
    print_check "Age key file"
    if [[ -f "$key_file" ]]; then
        print_pass "found at $key_file"

        print_check "Key format"
        if grep -q "AGE-SECRET-KEY-" "$key_file" 2>/dev/null; then
            print_pass "valid age secret key"
        else
            print_fail "invalid format"
        fi
    else
        print_warn "not found"
        print_info "Generate with: age-keygen -o ~/.config/sops/age/keys.txt"
    fi
}

check_project_files() {
    print_header "Project Configuration"

    print_check "flake.nix"
    if [[ -f "flake.nix" ]]; then
        print_pass "found"
    else
        print_fail "not found - are you in the project directory?"
        return 1
    fi

    print_check "deploy/deploy.sh"
    if [[ -x "deploy/deploy.sh" ]]; then
        print_pass "found and executable"
    else
        print_fail "not found or not executable"
    fi

    print_check "secrets/.sops.yaml"
    if [[ -f "secrets/.sops.yaml" ]]; then
        print_pass "found"
    else
        print_warn "not found - secrets not configured"
    fi

    print_check "secrets/secrets.yaml"
    if [[ -f "secrets/secrets.yaml" ]]; then
        print_pass "found (encrypted)"

        # Check if it's actually encrypted
        if grep -q "ENC\[AES256_GCM" "secrets/secrets.yaml" 2>/dev/null; then
            print_check "Secrets encrypted"
            print_pass "properly encrypted with sops"
        else
            print_warn "may not be properly encrypted"
        fi
    else
        print_warn "not found - see docs/GETTING_STARTED.md Step 3"
    fi

    print_check "hosts/registry.json"
    if [[ -f "hosts/registry.json" ]]; then
        local host_count
        host_count=$(jq 'keys | length' hosts/registry.json 2>/dev/null || echo "0")
        print_pass "found ($host_count hosts registered)"
    else
        print_info "no hosts registered yet"
    fi
}

check_remote() {
    local ip=$1

    print_header "Remote Server: $ip"

    print_check "SSH connection"
    if timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" "echo ok" &>/dev/null; then
        print_pass "connected as root"
    else
        print_fail "cannot connect (check SSH key and root access)"
        return 1
    fi

    print_check "KVM support"
    local kvm_result
    kvm_result=$(ssh -o BatchMode=yes "root@$ip" "cat /proc/cpuinfo | grep -cE '(vmx|svm)'" 2>/dev/null || echo "0")
    if [[ "$kvm_result" -gt 0 ]]; then
        print_pass "available ($kvm_result vCPUs with virtualization)"
    else
        print_fail "not available - virtualization not enabled"
        print_info "Enable virtualization in BIOS or use a KVM-capable cloud instance"
        return 1
    fi

    print_check "/dev/kvm accessible"
    if ssh -o BatchMode=yes "root@$ip" "test -e /dev/kvm" 2>/dev/null; then
        print_pass "present"
    else
        print_warn "not found (may be created after NixOS install)"
    fi

    print_check "Memory"
    local mem_kb
    mem_kb=$(ssh -o BatchMode=yes "root@$ip" "grep MemTotal /proc/meminfo | awk '{print \$2}'" 2>/dev/null || echo "0")
    local mem_mb=$((mem_kb / 1024))
    if [[ "$mem_mb" -ge 2048 ]]; then
        print_pass "${mem_mb}MB (sufficient)"
    elif [[ "$mem_mb" -ge 1024 ]]; then
        print_warn "${mem_mb}MB (minimum - consider 2GB+)"
    else
        print_fail "${mem_mb}MB (insufficient - need at least 2GB)"
    fi

    print_check "Disk space"
    local disk_gb
    disk_gb=$(ssh -o BatchMode=yes "root@$ip" "df -BG / | tail -1 | awk '{print \$4}' | tr -d 'G'" 2>/dev/null || echo "0")
    if [[ "$disk_gb" -ge 20 ]]; then
        print_pass "${disk_gb}GB available"
    elif [[ "$disk_gb" -ge 10 ]]; then
        print_warn "${disk_gb}GB available (consider 20GB+)"
    else
        print_fail "${disk_gb}GB available (need at least 10GB)"
    fi

    print_check "Architecture"
    local arch
    arch=$(ssh -o BatchMode=yes "root@$ip" "uname -m" 2>/dev/null || echo "unknown")
    if [[ "$arch" == "x86_64" ]] || [[ "$arch" == "aarch64" ]]; then
        print_pass "$arch (supported)"
    else
        print_fail "$arch (unsupported)"
    fi

    # Check if already running NixOS
    print_check "Current OS"
    if ssh -o BatchMode=yes "root@$ip" "test -f /etc/NIXOS" 2>/dev/null; then
        local nixos_version
        nixos_version=$(ssh -o BatchMode=yes "root@$ip" "cat /etc/os-release | grep VERSION_ID | cut -d= -f2" 2>/dev/null || echo "unknown")
        print_info "NixOS $nixos_version already installed"
    else
        local os_name
        os_name=$(ssh -o BatchMode=yes "root@$ip" "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "unknown")
        print_info "$os_name (will be replaced with NixOS)"
    fi
}

print_summary() {
    print_header "Summary"

    echo -e "  ${GREEN}Passed:${NC}  $PASS"
    echo -e "  ${YELLOW}Warnings:${NC} $WARN"
    echo -e "  ${RED}Failed:${NC}  $FAIL"
    echo ""

    if [[ $FAIL -eq 0 ]]; then
        if [[ $WARN -eq 0 ]]; then
            echo -e "  ${GREEN}${BOLD}All checks passed! You're ready to deploy.${NC}"
        else
            echo -e "  ${YELLOW}${BOLD}Ready to deploy with minor issues.${NC}"
            echo -e "  ${YELLOW}Review warnings above before proceeding.${NC}"
        fi
        echo ""
        echo -e "  ${BLUE}Next steps:${NC}"
        echo "    1. Configure secrets: sops secrets/secrets.yaml"
        echo "    2. Deploy: ./deploy/deploy.sh -p do -n runner-1 -t prod,github-runners,medium <ip>"
        echo "    3. Apply config: colmena apply --on runner-1 --build-on-target"
        echo ""
        return 0
    else
        echo -e "  ${RED}${BOLD}Please fix the failed checks before deploying.${NC}"
        echo ""
        echo -e "  ${BLUE}Documentation:${NC}"
        echo "    - Getting Started: docs/GETTING_STARTED.md"
        echo "    - Full README: README.md"
        echo ""
        return 1
    fi
}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --local           Check local environment only (default)"
    echo "  --remote <ip>     Check remote server only"
    echo "  --all <ip>        Check both local and remote"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                          # Check local environment"
    echo "  $0 --remote 167.71.100.50   # Check remote server"
    echo "  $0 --all 167.71.100.50      # Check both"
}

main() {
    local check_local=true
    local check_remote_flag=false
    local remote_ip=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --local)
                check_local=true
                check_remote_flag=false
                shift
                ;;
            --remote)
                check_local=false
                check_remote_flag=true
                remote_ip="$2"
                shift 2
                ;;
            --all)
                check_local=true
                check_remote_flag=true
                remote_ip="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo -e "${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║       nixos-fireactions Prerequisites Check               ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ "$check_local" == true ]]; then
        check_nix || true
        check_tools || true
        check_age_key || true
        check_project_files || true
    fi

    if [[ "$check_remote_flag" == true ]]; then
        if [[ -z "$remote_ip" ]]; then
            echo "Error: --remote and --all require an IP address"
            usage
            exit 1
        fi
        check_remote "$remote_ip" || true
    fi

    print_summary
}

main "$@"
