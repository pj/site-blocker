#!/bin/bash
# run-e2e.sh — build SiteBlocker on the host, copy it into the Tart VM, and run the end-to-end
# scenarios there. The VM carries no Swift toolchain, so both the app bundle and the sb-driver helper
# are compiled here and copied in (same arch, so they run unchanged). The scenarios themselves run
# inside the VM's GUI session, because the app is a menu-bar agent that needs one.
#
# Structure and the SSH/rsync helpers mirror vm/run-tests.sh in the window_thing repo.
#
#   ./vm/run-e2e.sh               # build, boot, run all scenarios
#   ./vm/run-e2e.sh --filter 02   # only scenarios whose file name contains "02"
#   ./vm/run-e2e.sh --keep        # leave the VM running afterwards
#   ./vm/run-e2e.sh --skip-unit   # skip the host-side RulesEngine unit tests
set -euo pipefail

VM_NAME="${VM_NAME:-macos-dev}"
SSH_USER="admin"
SSH_PASS="admin"
SSH_TIMEOUT=90
GUI_UID=501                       # the VM's logged-in console user (admin)
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR="~/Projects/$(basename "$PROJECT_DIR")"
HOST_APP="$PROJECT_DIR/build/Build/Products/Debug/SiteBlocker.app"
HOST_DRIVER="$PROJECT_DIR/build/sb-driver"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_tart()    { command -v tart    >/dev/null || { log_error "tart not installed (brew install cirruslabs/cli/tart)"; exit 1; }; }
check_sshpass() { command -v sshpass >/dev/null || { log_error "sshpass not installed (brew install hudochenkov/sshpass/sshpass)"; exit 1; }; }
check_vm()      { tart list | grep -q "${VM_NAME}" || { log_error "VM '${VM_NAME}' not found"; exit 1; }; }

is_vm_running() { tart list | grep "${VM_NAME}" | grep -q "running"; }
get_vm_ip()     { tart ip "$VM_NAME" 2>/dev/null || echo ""; }

# --------------------------------------------------------------------------- #
# SSH / rsync — password auth, upgrading to a key (macOS sshd rejects rapid    #
# password logins intermittently). Mirrors window_thing's helpers.            #
# --------------------------------------------------------------------------- #
SSH_BASE="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="$SSH_BASE -o IdentitiesOnly=yes -o PubkeyAuthentication=no"
SSH_MODE="password"

ensure_ssh_auth() {
    local ip=$1
    key_auth_works() {
        [ -f "$SSH_KEY" ] && ssh $SSH_BASE -i "$SSH_KEY" -o IdentitiesOnly=yes \
            -o PasswordAuthentication=no -o BatchMode=yes "${SSH_USER}@${ip}" true 2>/dev/null
    }
    if key_auth_works; then
        SSH_OPTS="$SSH_BASE -i $SSH_KEY -o IdentitiesOnly=yes -o PasswordAuthentication=no"; SSH_MODE="key"; return 0
    fi
    [ -f "${SSH_KEY}.pub" ] || { log_warn "no key at ${SSH_KEY}.pub — staying on password auth"; return 0; }
    local pub attempt; pub="$(cat "${SSH_KEY}.pub")"
    for attempt in 1 2 3 4 5; do
        if sshpass -p "$SSH_PASS" ssh $SSH_OPTS "${SSH_USER}@${ip}" \
             "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
              (grep -qxF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys); \
              chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then break; fi
        sleep 2
    done
    if key_auth_works; then
        SSH_OPTS="$SSH_BASE -i $SSH_KEY -o IdentitiesOnly=yes -o PasswordAuthentication=no"; SSH_MODE="key"
        log_info "SSH key authentication active"
    else
        log_warn "could not install an SSH key — staying on password auth"
    fi
}

ssh_run() {
    local ip=$1; shift; local attempt rc
    for attempt in 1 2 3 4 5; do
        if [ "$SSH_MODE" = "key" ]; then
            ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"; rc=$?; [ "$rc" -ne 255 ] && return "$rc"
        else
            sshpass -p "$SSH_PASS" ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"; rc=$?
            [ "$rc" -ne 255 ] && [ "$rc" -ne 5 ] && return "$rc"
        fi
        sleep 2
    done
    return "$rc"
}

rsync_vm() {  # rsync_vm <src> <dst-relative-to-remote-home-or-abs> [extra rsync args...]
    local src=$1 dst=$2; shift 2; local attempt
    for attempt in 1 2 3; do
        if [ "$SSH_MODE" = "key" ]; then
            rsync -az -e "ssh $SSH_OPTS" "$@" "$src" "${SSH_USER}@${ip}:${dst}" && return 0
        else
            sshpass -p "$SSH_PASS" rsync -az -e "ssh $SSH_OPTS" "$@" "$src" "${SSH_USER}@${ip}:${dst}" && return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_ssh() {
    local ip=$1 elapsed=0
    log_info "Waiting for SSH on $ip..."
    while ! nc -z "$ip" 22 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2))
        [ $elapsed -ge $SSH_TIMEOUT ] && { log_error "SSH timeout after ${SSH_TIMEOUT}s"; return 1; }
    done
    sleep 2; ensure_ssh_auth "$ip"
}

# --------------------------------------------------------------------------- #
# Build the two artifacts on the host                                           #
# --------------------------------------------------------------------------- #
build_artifacts() {
    log_info "Building SiteBlocker.app (host, Debug)"
    if ! (cd "$PROJECT_DIR" && just build) >/tmp/sb-e2e-build.log 2>&1; then
        log_error "app build failed:"; tail -25 /tmp/sb-e2e-build.log; return 1
    fi
    [ -d "$HOST_APP" ] || { log_error "no app at $HOST_APP after build"; return 1; }

    local src="$PROJECT_DIR/vm/scripts/sb-driver.swift"
    if [ ! -x "$HOST_DRIVER" ] || [ "$src" -nt "$HOST_DRIVER" ] \
       || find "$PROJECT_DIR/RulesEngine/Sources/RulesEngine" -name '*.swift' -newer "$HOST_DRIVER" | grep -q .; then
        log_info "Building sb-driver (host)"
        if ! swiftc -O "$PROJECT_DIR"/RulesEngine/Sources/RulesEngine/*.swift "$src" \
               -o "$HOST_DRIVER" 2>/tmp/sb-e2e-driver.log; then
            log_error "sb-driver build failed:"; tail -25 /tmp/sb-e2e-driver.log; return 1
        fi
    fi
}

usage() { echo "Usage: $0 [--keep] [--filter NAME] [--skip-unit]"; }

main() {
    local keep=false filter="" skip_unit=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --keep)      keep=true; shift ;;
            --filter)    filter="$2"; shift 2 ;;
            --skip-unit) skip_unit=true; shift ;;
            -h|--help)   usage; exit 0 ;;
            *) log_error "unknown option: $1"; usage; exit 1 ;;
        esac
    done

    check_tart; check_sshpass; check_vm

    # A compile error should not cost a VM boot.
    build_artifacts || exit 1

    local exit_code=0

    # Host-side unit tests first — fast, and a red here means no point driving the VM.
    if [ "$skip_unit" = false ]; then
        log_info "Running RulesEngine unit tests on the host..."
        if (cd "$PROJECT_DIR/RulesEngine" && swift test 2>&1); then
            log_info "Unit tests passed."
        else
            log_error "Unit tests failed."; exit_code=1
        fi
    fi

    [ "$keep" = true ] || trap 'log_info "Stopping VM..."; tart stop "$VM_NAME" 2>/dev/null || true' EXIT

    if is_vm_running; then log_info "VM already running"; else
        log_info "Starting VM headlessly..."; tart run "$VM_NAME" --no-graphics & sleep 5
    fi

    ip=""
    for _ in {1..30}; do ip=$(get_vm_ip); [ -n "$ip" ] && break; sleep 2; done
    [ -n "$ip" ] || { log_error "could not get VM IP"; exit 1; }
    log_info "VM IP: $ip"
    wait_for_ssh "$ip"

    log_info "Syncing harness + project to VM..."
    ssh_run "$ip" "mkdir -p $REMOTE_DIR/build $REMOTE_DIR/vm"
    # The harness scripts and the RulesEngine sources (small); exclude the big build tree and VCS.
    rsync_vm "$PROJECT_DIR/vm/" "$REMOTE_DIR/vm/" --delete --exclude 'screenshots'
    log_info "Copying the app and driver into the VM..."
    rsync_vm "$HOST_APP" "$REMOTE_DIR/build/" --delete
    rsync_vm "$HOST_DRIVER" "$REMOTE_DIR/build/sb-driver"
    ssh_run "$ip" "chmod +x $REMOTE_DIR/build/sb-driver"

    # The scenarios run in the logged-in GUI session. `launchctl asuser` injects them into that
    # session (an SSH session has none of its own, and the app cannot draw/run without one); `sudo -u`
    # then drops from root (asuser runs as root) back to the console user that owns the session.
    log_info "Running e2e scenarios in the VM's GUI session..."
    if ssh_run "$ip" "sudo launchctl asuser $GUI_UID sudo -u ${SSH_USER} /bin/bash -lc \
        'PROJECT_DIR=$REMOTE_DIR $REMOTE_DIR/vm/scripts/e2e-test.sh $filter' 2>&1"; then
        log_info "E2E scenarios passed."
    else
        log_error "E2E scenarios failed."; exit_code=1
    fi

    if [ "$keep" = true ]; then
        log_info "VM kept running (--keep). Connect with: sshpass -p '$SSH_PASS' ssh ${SSH_USER}@${ip}"
        trap - EXIT
    fi
    return $exit_code
}

main "$@"
