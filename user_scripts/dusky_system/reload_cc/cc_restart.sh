#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: restart_dusky_cc.sh
# Purpose: Forcefully manages the Dusky Control Center lifecycle.
#          1. Snapshots and terminates running instances (SIGTERM -> SIGKILL).
#          2. Resets systemd failure state.
#          3. Starts a clean systemd user service instance.
#          4. Signals the UI to activate (if applicable).
# Compatibility: Bash 5.0+, Arch Linux, UWSM/Hyprland
# Author: Elite DevOps Engineer
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# SIGNAL TRAP (CRITICAL)
# -----------------------------------------------------------------------------
# Ignore SIGHUP (1). If this script is launched by the Control Center itself,
# killing the parent process usually sends SIGHUP to children. We must ignore
# this to survive the restart sequence.
trap '' HUP

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly APP_NAME="Dusky Control Center"
readonly SERVICE_NAME="dusky.service"
# Regex: Escape the dot to ensure we only match the .py extension
readonly PROCESS_PATTERN='dusky_control_center\.py'
readonly GUI_SCRIPT_PATH="${HOME}/user_scripts/dusky_system/control_center/dusky_control_center.py"

# Timing Constants (Seconds)
readonly GRACE_PERIOD_LOOPS=20
readonly GRACE_SLEEP_SEC=0.1
readonly POST_KILL_SETTLE_SEC=0.2
readonly SERVICE_INIT_DELAY_SEC=0.3
readonly DBUS_REGISTRATION_DELAY_SEC=1

readonly SELF_PID=$$

# -----------------------------------------------------------------------------
# Terminal Colors (TTY Detection)
# -----------------------------------------------------------------------------
if [[ -t 1 && -t 2 ]]; then
    readonly C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
    readonly C_BLUE=$'\e[34m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
log_ok()      { printf '%s[OK]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_err()     { printf '%s[ERR]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }

# -----------------------------------------------------------------------------
# Preflight Checks
# -----------------------------------------------------------------------------
preflight_checks() {
    # 1. Privilege Check
    if ((EUID == 0)); then
        log_err "This script manages a user service. Do not run as root."
        return 1
    fi

    # 2. Dependency Verification
    local cmd
    local -a missing=()
    for cmd in pgrep systemctl journalctl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_err "Missing required binaries: ${missing[*]}"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Process Management
# -----------------------------------------------------------------------------

# Capture matching PIDs, filtering out THIS SCRIPT ONLY.
# We DO NOT filter out PPID, because the parent might be the app asking to restart.
get_target_pids() {
    local pid
    while IFS= read -r pid; do
        # Defensive: Validate numeric format before arithmetic comparison.
        if [[ "$pid" =~ ^[0-9]+$ ]] && ((pid != SELF_PID)); then
            printf '%s\n' "$pid"
        fi
    done < <(pgrep -f -- "$PROCESS_PATTERN" 2>/dev/null || true)
}

terminate_processes() {
    (($# > 0)) || return 0
    local -a pids=("$@")
    local pid i all_exited

    log_info "Terminating instances (PIDs: ${pids[*]})..."

    # Phase 1: Graceful Shutdown (SIGTERM)
    for pid in "${pids[@]}"; do
        kill -TERM -- "$pid" 2>/dev/null || true
    done

    # Phase 2: Polling Wait Loop
    for ((i = 0; i < GRACE_PERIOD_LOOPS; i++)); do
        all_exited=1
        for pid in "${pids[@]}"; do
            # kill -0 checks if process exists; returns 0 if yes
            if kill -0 -- "$pid" 2>/dev/null; then
                all_exited=0
                break
            fi
        done

        if ((all_exited)); then
            log_ok "Processes terminated gracefully."
            return 0
        fi
        sleep "$GRACE_SLEEP_SEC"
    done

    # Phase 3: The Double Tap (SIGKILL)
    log_warn "Grace period exceeded. Sending SIGKILL..."
    for pid in "${pids[@]}"; do
        kill -KILL -- "$pid" 2>/dev/null || true
    done
    
    # Brief pause for kernel process table cleanup
    sleep "$POST_KILL_SETTLE_SEC"
    log_ok "Forced termination complete."
}

# -----------------------------------------------------------------------------
# Service Management
# -----------------------------------------------------------------------------
start_and_verify_service() {
    log_info "Starting systemd service: ${C_BOLD}${SERVICE_NAME}${C_RESET}"

    # Reset 'failed' state which might block restart
    systemctl --user reset-failed -- "$SERVICE_NAME" 2>/dev/null || true

    if ! systemctl --user start -- "$SERVICE_NAME"; then
        log_err "systemctl start failed. Dumping logs:"
        journalctl --user -u "$SERVICE_NAME" -n 15 --no-pager >&2
        return 1
    fi

    # Allow time for the interpreter to initialize
    sleep "$SERVICE_INIT_DELAY_SEC"

    if ! systemctl --user is-active --quiet -- "$SERVICE_NAME"; then
        log_err "Service started but immediately exited. Dumping logs:"
        journalctl --user -u "$SERVICE_NAME" -n 10 --no-pager >&2
        return 1
    fi

    log_ok "Service is active."
}

# -----------------------------------------------------------------------------
# UI Activation
# -----------------------------------------------------------------------------
activate_ui() {
    # Check if script exists
    if [[ ! -f "$GUI_SCRIPT_PATH" ]]; then
        log_warn "UI script not found at: $GUI_SCRIPT_PATH"
        return 0
    fi

    log_info "Activating UI window..."

    # Robust launch: Handle missing +x bit and detach process.
    # We use 'python3 --' to defend against paths starting with hyphens.
    if [[ -x "$GUI_SCRIPT_PATH" ]]; then
        "$GUI_SCRIPT_PATH" &>/dev/null &
    else
        python3 -- "$GUI_SCRIPT_PATH" &>/dev/null &
    fi
    
    # Disown prevents the UI from closing when this script exits
    disown
}

# -----------------------------------------------------------------------------
# Main Orchestrator
# -----------------------------------------------------------------------------
main() {
    preflight_checks || return 1

    log_info "Initiating restart for ${C_BOLD}${APP_NAME}${C_RESET}..."

    # Step 1: Snapshot and terminate
    local -a target_pids
    mapfile -t target_pids < <(get_target_pids)

    if ((${#target_pids[@]} > 0)); then
        terminate_processes "${target_pids[@]}"
    else
        log_info "No running instances found. Environment is clean."
    fi

    # Step 2: Start Service
    start_and_verify_service || return 1

    # Step 3: Wait for DBus & Activate UI
    log_info "Waiting for DBus registration (${DBUS_REGISTRATION_DELAY_SEC}s)..."
    sleep "$DBUS_REGISTRATION_DELAY_SEC"
    
    activate_ui

    log_ok "Restart sequence complete."
}

main "$@"
