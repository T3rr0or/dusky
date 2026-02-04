#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Power Master (v2.6)
# -----------------------------------------------------------------------------
# Architecture: Atomic Writes + Robust Input Engine
# Fixes:
#   - CRASH FIX: Tab cycling no longer kills script on Tab 0 (set -e safety)
#   - FEATURE: Added [r]eset defaults option (Reads from internal defaults)
# -----------------------------------------------------------------------------

set -euo pipefail
export LC_NUMERIC=C

# =============================================================================
# ▼ ANSI DEFINITIONS ▼
# =============================================================================

readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'

# =============================================================================
# ▼ AUTO-ELEVATION ▼
# =============================================================================

if [[ ${EUID} -ne 0 ]]; then
    printf '%s[PRIVILEGE ESCALATION]%s This script requires root to edit logind.conf.\n' \
        "${C_YELLOW}" "${C_RESET}"
    exec sudo -- "$0" "$@"
fi

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

readonly CONFIG_FILE="/etc/systemd/logind.conf"
readonly APP_TITLE="Dusky Power Manager"
readonly APP_VERSION="v2.6"

declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_PADDING=32

# Internal marker for unset values
readonly UNSET_MARKER='«unset»'

# Generate horizontal line
declare _h_line_buf
printf -v _h_line_buf '%*s' "${BOX_INNER_WIDTH}" ''
readonly H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# Terminal Control
readonly CLR_EOL=$'\033[K'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# =============================================================================
# ▼ STATE MANAGEMENT ▼
# =============================================================================

declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -i UNSAVED_CHANGES=0

declare -a TABS=("Power Keys" "Lid & Idle" "Session")
declare -ri TAB_COUNT=${#TABS[@]}

# Data Structures
declare -A ITEM_SCHEMA=()    # label -> "key|type|opts"
declare -A VALUE_CACHE=()    # label -> current UI value
declare -A FILE_CACHE=()     # key   -> original disk value
declare -A DEFAULTS=()       # label -> default value [NEW]
declare -A TAB_REGISTRY=()   # "tab:row" -> label
declare -a TAB_ROW_COUNTS=() # tab_idx -> row count
declare -a TAB_ZONES=()      # click zones for tabs
declare ORIGINAL_STTY=""

for (( i = 0; i < TAB_COUNT; i++ )); do
    TAB_ROW_COUNTS[i]=0
done

# =============================================================================
# ▼ UTILITY FUNCTIONS ▼
# =============================================================================

log_err() {
    printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2
}

cleanup() {
    printf '%s%s%s\n' "${MOUSE_OFF}" "${CURSOR_SHOW}" "${C_RESET}"
    [[ -n ${ORIGINAL_STTY:-} ]] && stty "${ORIGINAL_STTY}" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# ▼ CORE ENGINE ▼
# =============================================================================

register() {
    local -i tab_idx=$1
    local label=$2
    local config=$3
    local default_val=${4:-}

    # Type Safety Validation
    local key type opts
    IFS='|' read -r key type opts <<< "$config"
    case "$type" in
        bool|int|float|cycle) ;;
        *)
            printf '%s[FATAL]%s Invalid type "%s" for "%s".\n' \
                   "${C_RED}" "${C_RESET}" "$type" "$label" >&2
            exit 1
            ;;
    esac

    ITEM_SCHEMA["${label}"]="${config}"
    
    # Store Default Value [NEW]
    DEFAULTS["${label}"]="${default_val}"

    local -i row=${TAB_ROW_COUNTS[tab_idx]}
    TAB_REGISTRY["${tab_idx}:${row}"]="${label}"
    (( TAB_ROW_COUNTS[tab_idx]++ )) || true

    VALUE_CACHE["${label}"]="${UNSET_MARKER}"
}

init_items() {
    local acts="ignore,poweroff,reboot,halt,suspend,hibernate,hybrid-sleep,suspend-then-hibernate,lock"

    # Tab 0: Hardware
    register 0 "Power Key"   "HandlePowerKey|cycle|${acts}"          "poweroff"
    register 0 "Reboot Key"  "HandleRebootKey|cycle|${acts}"         "reboot"
    register 0 "Suspend Key" "HandleSuspendKey|cycle|${acts}"        "suspend"
    register 0 "Long Press"  "HandlePowerKeyLongPress|cycle|${acts}" "ignore"

    # Tab 1: Lid & Idle
    register 1 "Lid Switch"   "HandleLidSwitch|cycle|${acts}"              "suspend"
    register 1 "Lid (Ext)"    "HandleLidSwitchExternalPower|cycle|${acts}" "suspend"
    register 1 "Lid (Docked)" "HandleLidSwitchDocked|cycle|${acts}"        "ignore"
    register 1 "Idle Action"  "IdleAction|cycle|${acts}"                   "ignore"
    register 1 "Idle Timeout" "IdleActionSec|cycle|15min,30min,45min,1h,2h,infinity" "30min"

    # Tab 2: Session
    register 2 "Kill User Procs" "KillUserProcesses|cycle|yes,no" "no"
    register 2 "Reserve VTs"     "ReserveVT|int|0 12"             "6"
}

parse_config() {
    local line key val
    FILE_CACHE=()

    if [[ ! -f ${CONFIG_FILE} ]]; then
        log_err "Config file not found: ${CONFIG_FILE}"
        return 1
    fi

    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ -z ${line} || ${line} == "["* ]] && continue

        if [[ ${line} =~ ^#?([A-Za-z]+)=(.*)$ ]]; then
            key=${BASH_REMATCH[1]}
            val=${BASH_REMATCH[2]}
            val=${val%%#*}
            val=${val// /}
            FILE_CACHE["${key}"]="${val}"
        fi
    done < "${CONFIG_FILE}"
}

load_values_to_ui() {
    local tab row label key type opts default_val
    
    for (( tab = 0; tab < TAB_COUNT; tab++ )); do
        for (( row = 0; row < TAB_ROW_COUNTS[tab]; row++ )); do
            label=${TAB_REGISTRY["${tab}:${row}"]}
            IFS='|' read -r key type opts <<< "${ITEM_SCHEMA[${label}]}"

            if [[ -n ${FILE_CACHE[${key}]:-} ]]; then
                VALUE_CACHE["${label}"]="${FILE_CACHE[${key}]}"
            else
                VALUE_CACHE["${label}"]="${UNSET_MARKER}"
            fi
        done
    done
}

# =============================================================================
# ▼ VALUE MUTATION ▼
# =============================================================================

modify_value() {
    local label=$1
    local -i direction=$2
    local key type opts current new_val
    local -a opt_arr

    IFS='|' read -r key type opts <<< "${ITEM_SCHEMA[${label}]}"
    current=${VALUE_CACHE[${label}]}

    # Handle UNSET values
    if [[ "${current}" == "${UNSET_MARKER}" ]]; then
        # If unset, use default as starting point
        current=${DEFAULTS[${label}]}
    fi

    if [[ ${type} == "int" ]]; then
        local -i min max int_val
        min=${opts%% *}
        max=${opts##* }
        [[ ! ${current} =~ ^-?[0-9]+$ ]] && current=${min}
        int_val=${current}
        (( int_val += direction )) || true
        (( int_val < min )) && int_val=${min}
        (( int_val > max )) && int_val=${max}
        new_val=${int_val}
    else
        IFS=',' read -r -a opt_arr <<< "${opts}"
        local -i idx=0 arr_len=${#opt_arr[@]}
        for (( i = 0; i < arr_len; i++ )); do
            [[ ${opt_arr[i]} == "${current}" ]] && { idx=${i}; break; }
        done
        (( idx += direction )) || true
        (( idx < 0 )) && idx=$(( arr_len - 1 ))
        (( idx >= arr_len )) && idx=0
        new_val=${opt_arr[idx]}
    fi

    if [[ ${current} != "${new_val}" ]]; then
        VALUE_CACHE["${label}"]="${new_val}"
        UNSAVED_CHANGES=1
    fi
}

reset_defaults() {
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    local row label def_val

    for (( row = 0; row < count; row++ )); do
        label=${TAB_REGISTRY["${CURRENT_TAB}:${row}"]}
        def_val=${DEFAULTS["${label}"]:-}

        if [[ -n "${def_val}" && "${VALUE_CACHE[${label}]}" != "${def_val}" ]]; then
            VALUE_CACHE["${label}"]="${def_val}"
            UNSAVED_CHANGES=1
        fi
    done
}

# =============================================================================
# ▼ ATOMIC CONFIGURATION SAVE ▼
# =============================================================================

save_config() {
    local tab row label key type opts val
    local -i changes=0
    local -a pending_changes=()

    for (( tab = 0; tab < TAB_COUNT; tab++ )); do
        for (( row = 0; row < TAB_ROW_COUNTS[tab]; row++ )); do
            label=${TAB_REGISTRY["${tab}:${row}"]}
            IFS='|' read -r key type opts <<< "${ITEM_SCHEMA[${label}]}"
            val=${VALUE_CACHE[${label}]}

            # Ignore if still unset or matches file
            [[ "${val}" == "${UNSET_MARKER}" ]] && continue
            [[ "${val}" == "${FILE_CACHE[${key}]:-}" ]] && continue

            pending_changes+=("${key}=${val}")
            (( changes++ )) || true
        done
    done

    (( changes == 0 )) && return 1

    local tmpfile
    tmpfile=$(mktemp) || { log_err "Failed to create temp file"; return 1; }
    trap 'rm -f "${tmpfile}" 2>/dev/null' RETURN

    cp -- "${CONFIG_FILE}" "${tmpfile}"

    local change_key change_val escaped_val
    for change in "${pending_changes[@]}"; do
        change_key=${change%%=*}
        change_val=${change#*=}

        # Escaping
        escaped_val=${change_val//\\/\\\\}
        escaped_val=${escaped_val//&/\\&}
        escaped_val=${escaped_val//|/\\|}
        escaped_val=${escaped_val//$'\n'/\\n}
        escaped_val=${escaped_val//-/\\-}

        if grep -q -E "^#?${change_key}=" "${tmpfile}"; then
            sed -i -E "s|^#?(${change_key}=).*|\1${escaped_val}|" "${tmpfile}"
        elif grep -q '^\[Login\]' "${tmpfile}"; then
            sed -i "/^\[Login\]/a ${change_key}=${escaped_val}" "${tmpfile}"
        else
            printf '\n[Login]\n%s=%s\n' "${change_key}" "${escaped_val}" >> "${tmpfile}"
        fi

        FILE_CACHE["${change_key}"]="${change_val}"
    done

    mv -- "${tmpfile}" "${CONFIG_FILE}" || { log_err "Failed to write config"; return 1; }
    UNSAVED_CHANGES=0
    pkill -HUP -x systemd-logind 2>/dev/null || true
    return 0
}

# =============================================================================
# ▼ UI RENDERING ▼
# =============================================================================

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    local status_txt="${APP_VERSION}"
    local status_clr="${C_CYAN}"
    if (( UNSAVED_CHANGES )); then
        status_txt="UNSAVED"
        status_clr="${C_YELLOW}"
    fi

    visible_len=$(( ${#APP_TITLE} + ${#status_txt} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "${left_pad}" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${status_clr}${status_txt}${C_MAGENTA}"
    printf -v pad_buf '%*s' "${right_pad}" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()
    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        len=${#name}
        zone_start=${current_col}

        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi

        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 )) || true
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    (( pad_needed > 0 )) && { printf -v pad_buf '%*s' "${pad_needed}" ''; tab_line+="${pad_buf}"; }
    tab_line+="${C_MAGENTA}│${C_RESET}"
    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    count=${TAB_ROW_COUNTS[CURRENT_TAB]}

    if (( count == 0 )); then
        SELECTED_ROW=0
    else
        (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    fi

    (( SELECTED_ROW < SCROLL_OFFSET )) && SCROLL_OFFSET=${SELECTED_ROW}
    (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )) && \
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))

    (( SCROLL_OFFSET > 0 )) && buf+="  ${C_GREY}▲${C_RESET}"$'\n' || buf+=$'\n'

    for (( i = SCROLL_OFFSET; i < SCROLL_OFFSET + MAX_DISPLAY_ROWS; i++ )); do
        if (( i >= count )); then
            buf+="${CLR_EOL}"$'\n'
            continue
        fi

        item=${TAB_REGISTRY["${CURRENT_TAB}:${i}"]}
        val=${VALUE_CACHE[${item}]}

        case ${val} in
            yes|true)          display="${C_GREEN}YES${C_RESET}" ;;
            no|false)          display="${C_RED}NO${C_RESET}" ;;
            "${UNSET_MARKER}") display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            poweroff)          display="${C_RED}${val}${C_RESET}" ;;
            suspend)           display="${C_CYAN}${val}${C_RESET}" ;;
            ignore)            display="${C_GREY}${val}${C_RESET}" ;;
            *)                 display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:ITEM_PADDING}"

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    (( count > SCROLL_OFFSET + MAX_DISPLAY_ROWS )) && buf+="  ${C_GREY}▼${C_RESET}"$'\n' || buf+=$'\n'

    buf+=$'\n'"${C_CYAN} [Tab] Switch  [r]eset  [s] Save  [Arrows] Nav  [q] Quit${C_RESET}"$'\n'
    printf '%s' "${buf}"
}

# =============================================================================
# ▼ INPUT HANDLING ▼
# =============================================================================

navigate() {
    local -i dir=$1
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir )) || true
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
    return 0
}

navigate_page() {
    local -i dir=$1
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir * MAX_DISPLAY_ROWS )) || true
    # Clamp
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
    return 0
}

navigate_end() {
    local -i target=$1 # 0=top, 1=bottom
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    (( count == 0 )) && return 0
    (( target == 0 )) && SELECTED_ROW=0 || SELECTED_ROW=$(( count - 1 ))
    return 0
}

switch_tab() {
    local -i dir=${1:-1}
    # FIX: Added '|| :' to prevent crash when arithmetic result is 0
    (( CURRENT_TAB += dir )) || :
    (( CURRENT_TAB >= TAB_COUNT )) && CURRENT_TAB=0
    (( CURRENT_TAB < 0 )) && CURRENT_TAB=$(( TAB_COUNT - 1 ))
    
    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_values_to_ui
}

handle_mouse() {
    local input=$1
    local -i button x y i start end
    local match_type zone 
    local regex='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'

    [[ ! ${input} =~ ${regex} ]] && return 0

    button=${BASH_REMATCH[1]}
    x=${BASH_REMATCH[2]}
    y=${BASH_REMATCH[3]}
    match_type=${BASH_REMATCH[4]}

    (( button == 64 )) && { navigate -1; return 0; }
    (( button == 65 )) && { navigate 1; return 0; }

    [[ ${match_type} != "M" ]] && return 0

    if (( y == 3 )); then
        for (( i = 0; i < TAB_COUNT; i++ )); do
            zone=${TAB_ZONES[i]}
            start=${zone%%:*}
            end=${zone##*:}
            if (( x >= start && x <= end )); then
                CURRENT_TAB=${i}
                SELECTED_ROW=0
                SCROLL_OFFSET=0
                # Need to refresh load in case tab switch logic needs it
                load_values_to_ui
                return 0
            fi
        done
    fi
}

# =============================================================================
# ▼ MAIN ▼
# =============================================================================

main() {
    if (( BASH_VERSINFO[0] < 5 )); then
        log_err "Bash 5.0+ required (found: ${BASH_VERSION})"
        exit 1
    fi

    local -a required_cmds=(sed pkill grep)
    local cmd
    for cmd in "${required_cmds[@]}"; do
        command -v "${cmd}" >/dev/null 2>&1 || { log_err "Required: ${cmd}"; exit 1; }
    done

    init_items
    parse_config || exit 1
    load_values_to_ui

    command -v stty >/dev/null 2>&1 && ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""

    printf '%s%s%s%s' "${MOUSE_ON}" "${CURSOR_HIDE}" "${CLR_SCREEN}" "${CURSOR_HOME}"

    local key seq char
    while true; do
        draw_ui
        IFS= read -rsn1 key || break

        if [[ ${key} == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.01 char; do seq+="${char}"; done
            case ${seq} in
                '[Z')          switch_tab -1 ;;
                '[A'|'OA')     navigate -1 ;;
                '[B'|'OB')     navigate 1 ;;
                '[C'|'OC')     modify_value "${TAB_REGISTRY["${CURRENT_TAB}:${SELECTED_ROW}"]}" 1 ;;
                '[D'|'OD')     modify_value "${TAB_REGISTRY["${CURRENT_TAB}:${SELECTED_ROW}"]}" -1 ;;
                '[5~')         navigate_page -1 ;;
                '[6~')         navigate_page 1 ;;
                '[H'|'[1~')    navigate_end 0 ;;
                '[F'|'[4~')    navigate_end 1 ;;
                '['*'<'*)      handle_mouse "${seq}" ;;
            esac
        else
            case ${key} in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                l|L)           modify_value "${TAB_REGISTRY["${CURRENT_TAB}:${SELECTED_ROW}"]}" 1 ;;
                h|H)           modify_value "${TAB_REGISTRY["${CURRENT_TAB}:${SELECTED_ROW}"]}" -1 ;;
                g)             navigate_end 0 ;;
                G)             navigate_end 1 ;;
                s|S)           save_config || true ;;
                r|R)           reset_defaults ;;
                $'\t')         switch_tab 1 ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done

    if (( UNSAVED_CHANGES )); then
        printf '%s%s%s' "${MOUSE_OFF}" "${CURSOR_SHOW}" "${C_RESET}"
        clear
        printf '%sUnsaved changes detected. Save? [Y/n] %s' "${C_YELLOW}" "${C_RESET}"
        local yn=""
        read -r -n 1 yn
        printf '\n'
        [[ ! ${yn} =~ ^[Nn]$ ]] && save_config
    fi
}

main "$@"
