#!/usr/bin/env bash
# Waybar Theme Manager (wtm)
# Description: Live preview, smart configuration, and symlinking for Waybar themes.
# Environment: Arch Linux / Hyprland / UWSM
# Author: Elite DevOps Engineer
# -----------------------------------------------------------------------------

#  Options:
#    --toggle       Cycle to the next theme alphabetically (no TUI)
#    --back_toggle  Cycle to the previous theme alphabetically (no TUI)
#    -h, --help     Show this help

set -euo pipefail

# --- Bash Version Gate ---
if (( BASH_VERSINFO[0] < 5 )); then
    printf 'FATAL: Bash 5.0+ required (current: %s)\n' "$BASH_VERSION" >&2
    exit 1
fi

# --- Configuration & Constants ---
readonly CONFIG_ROOT="${HOME}/.config/waybar"
readonly -a UWSM_CMD=(uwsm-app --)
readonly KILL_TIMEOUT=20   # 20 * 0.1s = 2s max wait

# --- Runtime State ---
declare -i PREVIEW_PID=0
declare -i SELECTED_IDX=0
declare IS_TOGGLE=false
declare IS_BACK_TOGGLE=false
declare TUI_ACTIVE=false
declare FINALIZED=false

# Original state for restoration
declare ORIG_CONFIG=""
declare ORIG_STYLE=""

# --- Colors ---
readonly R=$'\033[0;31m' G=$'\033[0;32m' B=$'\033[0;34m'
readonly Y=$'\033[1;33m' C=$'\033[0;36m' NC=$'\033[0m' BOLD=$'\033[1m'

# --- Logging ---
log_info()    { printf '%s[INFO]%s %s\n' "$B" "$NC" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$G" "$NC" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n' "$Y" "$NC" "$*" >&2; }
log_err()     { printf '%s[ERROR]%s %s\n' "$R" "$NC" "$*" >&2; }

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]

A TUI theme manager for Waybar with live preview.

Options:
  --toggle       Cycle to the next theme alphabetically (no TUI)
  --back_toggle  Cycle to the previous theme alphabetically (no TUI)
  -h, --help     Show this help

Themes discovered from: ${CONFIG_ROOT}/<theme>/config.jsonc
EOF
}

# --- Argument Parsing ---
while (( $# > 0 )); do
    case "$1" in
        --toggle)      IS_TOGGLE=true ;;
        --back_toggle) IS_BACK_TOGGLE=true ;;
        -h|--help)     usage; exit 0 ;;
        *)             log_err "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# Determine mode
declare -r IS_INTERACTIVE=$([[ $IS_TOGGLE == false && $IS_BACK_TOGGLE == false ]] && echo true || echo false)

# --- Pre-flight Checks ---
(( EUID == 0 )) && { log_err "This script must not be run as root."; exit 1; }
[[ -z "${WAYLAND_DISPLAY:-}" ]] && { log_err "No Wayland display detected."; exit 1; }
[[ -d "$CONFIG_ROOT" ]] || { log_err "Directory $CONFIG_ROOT does not exist."; exit 1; }

# --- Dependency Check ---
for cmd in waybar uwsm-app setsid tput; do
    command -v "$cmd" &>/dev/null || { log_err "Missing dependency: $cmd"; exit 1; }
done

# --- Helper Functions ---

kill_waybar() {
    pkill -x waybar 2>/dev/null || true
    local -i i
    for (( i = 0; i < KILL_TIMEOUT; i++ )); do
        pgrep -x waybar &>/dev/null || return 0
        sleep 0.1
    done
    log_warn "Waybar refused to close gracefully; forcing kill..."
    pkill -9 -x waybar 2>/dev/null || true
    sleep 0.1
}

# Starts the preview in the background. 
# Moved to top-level to ensure clean scope.
start_preview() {
    local theme_path="$1"

    rm -f "${CONFIG_ROOT}/config.jsonc" "${CONFIG_ROOT}/style.css"
    ln -snf "${theme_path}/config.jsonc" "${CONFIG_ROOT}/config.jsonc"
    [[ -f "${theme_path}/style.css" ]] && \
        ln -snf "${theme_path}/style.css" "${CONFIG_ROOT}/style.css"

    if (( PREVIEW_PID > 0 )); then
        kill "$PREVIEW_PID" 2>/dev/null || true
        wait "$PREVIEW_PID" 2>/dev/null || true
    fi

    kill_waybar

    "${UWSM_CMD[@]}" waybar &>/dev/null &
    PREVIEW_PID=$!
    sleep 0.3
}

# --- Cleanup Trap ---
cleanup() {
    local -i exit_code=$?

    # Always restore terminal cursor and sanity
    tput cnorm 2>/dev/null || true
    stty sane 2>/dev/null || true

    # Skip process cleanup if successfully finalized
    [[ "$FINALIZED" == "true" ]] && exit "$exit_code"

    # Kill preview wrapper if running
    if (( PREVIEW_PID > 0 )); then
        kill "$PREVIEW_PID" 2>/dev/null || true
        wait "$PREVIEW_PID" 2>/dev/null || true
    fi

    # Ensure waybar is gone on abnormal exit
    pkill -x waybar 2>/dev/null || true

    # Restore original symlinks only if TUI was active and interrupted
    if [[ "$TUI_ACTIVE" == "true" && -n "$ORIG_CONFIG" ]]; then
        rm -f "${CONFIG_ROOT}/config.jsonc" "${CONFIG_ROOT}/style.css"
        ln -snf "$ORIG_CONFIG" "${CONFIG_ROOT}/config.jsonc"
        [[ -n "$ORIG_STYLE" ]] && ln -snf "$ORIG_STYLE" "${CONFIG_ROOT}/style.css"
    fi

    exit "$exit_code"
}
trap cleanup EXIT

# --- Capture Original Symlinks ---
[[ -L "${CONFIG_ROOT}/config.jsonc" ]] && ORIG_CONFIG=$(readlink "${CONFIG_ROOT}/config.jsonc")
[[ -L "${CONFIG_ROOT}/style.css" ]]    && ORIG_STYLE=$(readlink "${CONFIG_ROOT}/style.css")

# --- Discovery Phase ---
declare -a THEMES=()
declare -a THEME_NAMES=()

shopt -s nullglob
for dir in "${CONFIG_ROOT}"/*/; do
    dir="${dir%/}"
    if [[ -f "${dir}/config.jsonc" ]]; then
        THEMES+=("$dir")
        THEME_NAMES+=("${dir##*/}")
    fi
done
shopt -u nullglob

if (( ${#THEMES[@]} == 0 )); then
    log_err "No valid theme directories found in $CONFIG_ROOT."
    exit 1
fi

declare -ir TOTAL=${#THEMES[@]}

# --- Resolve Current Index ---
get_current_index() {
    local cfg="${CONFIG_ROOT}/config.jsonc"
    [[ -e "$cfg" ]] || { echo -1; return; }

    local real_path current_dir
    real_path=$(readlink -f "$cfg" 2>/dev/null) || { echo -1; return; }
    current_dir="${real_path%/*}"

    local -i i
    for (( i = 0; i < TOTAL; i++ )); do
        if [[ "$(readlink -f "${THEMES[i]}")" == "$current_dir" ]]; then
            echo "$i"
            return
        fi
    done
    echo -1
}

# --- Logic Fork: Toggle vs TUI ---
if [[ "$IS_INTERACTIVE" == "false" ]]; then
    declare -i cur_idx
    cur_idx=$(get_current_index)
    
    cur_name="(unknown)"
    (( cur_idx >= 0 )) && cur_name="${THEME_NAMES[cur_idx]}"

    if (( cur_idx < 0 )); then
        SELECTED_IDX=0
        log_warn "Current config not recognized or broken. Resetting to first theme."
    else
        if [[ "$IS_TOGGLE" == "true" ]]; then
            SELECTED_IDX=$(( (cur_idx + 1) % TOTAL ))
        else
            SELECTED_IDX=$(( (cur_idx - 1 + TOTAL) % TOTAL ))
        fi
    fi

    log_info "Toggle mode: Switching from '${cur_name}' to '${THEME_NAMES[SELECTED_IDX]}'"

else
    # --- TUI Mode ---
    TUI_ACTIVE=true

    tput civis 2>/dev/null || true
    start_preview "${THEMES[SELECTED_IDX]}"

    while true; do
        printf '\033[H\033[2J'
        printf '%sWaybar Theme Selector%s (Use %sArrows/jk%s to browse, %sEnter%s to select, %sq%s to quit)\n\n' \
            "$BOLD" "$NC" "$Y" "$NC" "$G" "$NC" "$R" "$NC"

        for (( i = 0; i < TOTAL; i++ )); do
            if (( i == SELECTED_IDX )); then
                printf '%s> %s%s%s\n' "$C" "$BOLD" "${THEME_NAMES[i]}" "$NC"
            else
                printf '  %s\n' "${THEME_NAMES[i]}"
            fi
        done

        # FIX: Removed 'local' as this loop is in global scope
        key="" rest=""
        IFS= read -rsn1 key || true
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.1 rest || true
            key+="$rest"
        fi

        case "$key" in
            $'\x1b[A'|k)
                SELECTED_IDX=$(( (SELECTED_IDX - 1 + TOTAL) % TOTAL ))
                start_preview "${THEMES[SELECTED_IDX]}"
                ;;
            $'\x1b[B'|j)
                SELECTED_IDX=$(( (SELECTED_IDX + 1) % TOTAL ))
                start_preview "${THEMES[SELECTED_IDX]}"
                ;;
            '')
                TUI_ACTIVE=false
                break
                ;;
            q|Q)
                log_info "Selection cancelled."
                exit 0
                ;;
        esac
    done
    tput cnorm 2>/dev/null || true
fi

# --- Finalization Phase ---

if (( PREVIEW_PID > 0 )); then
    kill "$PREVIEW_PID" 2>/dev/null || true
    wait "$PREVIEW_PID" 2>/dev/null || true
fi

kill_waybar

readonly FINAL_THEME_DIR="${THEMES[SELECTED_IDX]}"
readonly FINAL_NAME="${THEME_NAMES[SELECTED_IDX]}"
readonly CONFIG_FILE="${FINAL_THEME_DIR}/config.jsonc"

if [[ "$IS_INTERACTIVE" == "true" ]]; then
    printf '\n%sSelected Theme:%s %s\n' "$B" "$NC" "$FINAL_NAME"
fi

# --- Smart Position Detection & Adjustment ---
if [[ "$IS_INTERACTIVE" == "true" ]]; then
    current_pos=""
    # Optimized: Use bash regex instead of grep|sed pipeline
    if [[ "$(<"$CONFIG_FILE")" =~ \"position\"[[:space:]]*:[[:space:]]*\"([a-z]+)\" ]]; then
        current_pos="${BASH_REMATCH[1]}"
    fi

    target_pos=""
    if [[ -z "$current_pos" ]]; then
        log_warn "Could not detect 'position' in config.jsonc. Skipping position adjustment."
    else
        case "$current_pos" in
            top|bottom)
                printf 'Detected %sHorizontal%s bar (currently: %s).\n' "$Y" "$NC" "$current_pos"
                printf 'Where do you want it? [t]op / [b]ottom (Enter to keep): '
                IFS= read -rn1 choice || choice=""
                printf '\n'
                [[ "$choice" == [tT] ]] && target_pos="top"
                [[ "$choice" == [bB] ]] && target_pos="bottom"
                ;;
            left|right)
                printf 'Detected %sVertical%s bar (currently: %s).\n' "$Y" "$NC" "$current_pos"
                printf 'Where do you want it? [l]eft / [r]ight (Enter to keep): '
                IFS= read -rn1 choice || choice=""
                printf '\n'
                [[ "$choice" == [lL] ]] && target_pos="left"
                [[ "$choice" == [rR] ]] && target_pos="right"
                ;;
        esac
    fi

    if [[ -n "$target_pos" && "$target_pos" != "$current_pos" ]]; then
        log_info "Updating config position to '$target_pos'..."
        sed -i -E "s/(\"position\"[[:space:]]*:[[:space:]]*)\"[^\"]+\"/\1\"${target_pos}\"/" "$CONFIG_FILE"
        log_success "Position updated."
    fi
fi

# --- Create Symlinks ---
[[ "$IS_INTERACTIVE" == "true" ]] && log_info "Creating symlinks..."

rm -f "${CONFIG_ROOT}/config.jsonc" "${CONFIG_ROOT}/style.css"

ln -snf "${FINAL_THEME_DIR}/config.jsonc" "${CONFIG_ROOT}/config.jsonc"
[[ "$IS_INTERACTIVE" == "true" ]] && \
    log_success "Symlink: config.jsonc -> ${FINAL_THEME_DIR}/config.jsonc"

if [[ -f "${FINAL_THEME_DIR}/style.css" ]]; then
    ln -snf "${FINAL_THEME_DIR}/style.css" "${CONFIG_ROOT}/style.css"
    [[ "$IS_INTERACTIVE" == "true" ]] && \
        log_success "Symlink: style.css -> ${FINAL_THEME_DIR}/style.css"
elif [[ "$IS_INTERACTIVE" == "true" ]]; then
    log_warn "No style.css found. Only config.jsonc was linked."
fi

# --- Start Final Waybar ---
[[ "$IS_INTERACTIVE" == "true" ]] && log_info "Starting Waybar via UWSM..."

FINALIZED=true

stty sane 2>/dev/null || true

setsid --fork "${UWSM_CMD[@]}" waybar </dev/null &>/dev/null

sleep 0.5

[[ "$IS_INTERACTIVE" == "true" ]] && log_success "Done. Enjoy your new setup!"

exit 0
