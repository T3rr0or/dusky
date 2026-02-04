#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky TUI Engine - Battery Notification Configurator
# -----------------------------------------------------------------------------
# Target: ~/user_scripts/battery/notify/battery_notify.sh
# Type: Bash Parameter Expansion Injector
# -----------------------------------------------------------------------------

set -euo pipefail
export LC_NUMERIC=C

# =============================================================================
# ▼ USER CONFIGURATION ▼
# =============================================================================

readonly CONFIG_FILE="${HOME}/user_scripts/battery/notify/battery_notify.sh"
readonly SERVICE_NAME="battery_notify.service"
readonly APP_TITLE="Dusky Battery Notif"
readonly APP_VERSION="v1.1.2" # Bumped version for Logic Engine

# Dimensions
declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_START_ROW=5
declare -ri ADJUST_THRESHOLD=40
declare -ri ITEM_PADDING=34

readonly -a TABS=("Thresholds" "Timers" "System")

# -----------------------------------------------------------------------------
# Item Registration
# -----------------------------------------------------------------------------
register_items() {
    # --- Tab 0: Thresholds ---
    # Key: BATTERY_FULL_THRESHOLD
    register 0 "Full Threshold (%)"     'BATTERY_FULL_THRESHOLD|int||80|100|1' "100"
    
    # Key: BATTERY_LOW_THRESHOLD
    register 0 "Low Threshold (%)"      'BATTERY_LOW_THRESHOLD|int||15|50|1'   "20"
    
    # Key: BATTERY_CRITICAL_THRESHOLD
    register 0 "Critical Threshold (%)" 'BATTERY_CRITICAL_THRESHOLD|int||2|15|1' "10"
    
    # Key: BATTERY_UNPLUG_THRESHOLD
    register 0 "Unplug Notify Limit (%)" 'BATTERY_UNPLUG_THRESHOLD|int||0|100|5' "100"

    # --- Tab 1: Timers ---
    # Key: REPEAT_FULL_MIN
    register 1 "Repeat: Full (min)"     'REPEAT_FULL_MIN|int||10|1440|10'      "999"
    
    # Key: REPEAT_LOW_MIN
    register 1 "Repeat: Low (min)"      'REPEAT_LOW_MIN|int||1|60|1'           "3"
    
    # Key: REPEAT_CRITICAL_MIN
    register 1 "Repeat: Critical (min)" 'REPEAT_CRITICAL_MIN|int||1|10|1'      "1"

    # Key: SAFETY_POLL_INTERVAL
    register 1 "Safety Poll (sec)"      'SAFETY_POLL_INTERVAL|int||10|300|10'  "60"

    # --- Tab 2: System / Actions ---
    # Key: SUSPEND_GRACE_SEC
    register 2 "Suspend Grace (sec)"    'SUSPEND_GRACE_SEC|int||15|300|15'     "60"
    
    # Key: CMD_CRITICAL
    register 2 "Critical Action"        'CMD_CRITICAL|cycle||systemctl suspend,systemctl hibernate,poweroff,loginctl lock-session||' "systemctl suspend"
}

# -----------------------------------------------------------------------------
# Post-Write Hook: Restart the Service
# -----------------------------------------------------------------------------
post_write_action() {
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        systemctl --user restart "$SERVICE_NAME"
    fi
}

# =============================================================================
# ▲ END OF USER CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _H_LINE_BUF
printf -v _H_LINE_BUF '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE="${_H_LINE_BUF// /─}"

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

readonly ESC_READ_TIMEOUT=0.02
readonly UNSET_MARKER='«unset»'

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""
declare STATUS_MSG=""

declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()

# Pre-declare arrays
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() 

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n'
}

escape_sed_replacement() {
    local -n __out=$2
    local _s=$1
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}
    _s=${_s//&/\\&}
    _s=${_s//$'\n'/\\n}
    __out=$_s
}

# -----------------------------------------------------------------------------
# Core Engine
# -----------------------------------------------------------------------------

register() {
    local -i tab_idx=$1
    local label=$2 config=$3 default_val=${4:-}
    local key type block min max step
    IFS='|' read -r key type block min max step <<< "$config"
    ITEM_MAP["$label"]=$config
    [[ -n "$default_val" ]] && DEFAULTS["$label"]=$default_val
    local -n tab_ref="TAB_ITEMS_${tab_idx}"
    tab_ref+=("$label")
}

populate_config_cache() {
    CONFIG_CACHE=()
    local key val
    while read -r key val; do
        [[ -z $key ]] && continue
        CONFIG_CACHE["$key"]=$val
    done < <(grep -E '^[[:space:]]*readonly[[:space:]]+[A-Z_]+="\$\{[A-Z_]+:-[^}]+\}"' "$CONFIG_FILE" | \
        sed -E 's/^[[:space:]]*readonly[[:space:]]+([A-Z_]+)="\$\{[A-Z_]+:-(.*)\}"/\1 \2/')
}

write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local current_val=${CONFIG_CACHE["$key"]:-}
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val
    escape_sed_replacement "$new_val" safe_val
    
    if sed -i -E "s|^([[:space:]]*readonly[[:space:]]+${key}=\"\\\$\{${key}:-)(.*)(\}\")|\1${safe_val}\3|" "$CONFIG_FILE"; then
        CONFIG_CACHE["$key"]=$new_val
        return 0
    fi
    return 1
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key val
    for item in "${items_ref[@]}"; do
        IFS='|' read -r key _ _ _ _ _ <<< "${ITEM_MAP[$item]}"
        val=${CONFIG_CACHE["$key"]:-}
        if [[ -z $val ]]; then
            VALUE_CACHE["$item"]=$UNSET_MARKER
        else
            VALUE_CACHE["$item"]=$val
        fi
    done
}

# Helper for logic checks
get_cached_int() {
    local key=$1
    local default=$2
    local val=${CONFIG_CACHE["$key"]:-}
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%d' "$val"
    else
        printf '%d' "$default"
    fi
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val
    
    STATUS_MSG="" # Clear status on new attempt

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP[$label]}"
    current=${VALUE_CACHE[$label]:-}
    
    if [[ $current == "$UNSET_MARKER" || -z $current ]]; then
        current=${DEFAULTS[$label]:-}
        [[ -z $current ]] && current=${min:-0}
    fi

    case $type in
        int)
            # --- INTELLIGENT LOGIC CONSTRAINTS ---
            # Dynamic boundaries to prevent Logical Errors (Critical < Low < Full)
            local -i limit_val
            
            if [[ "$key" == "BATTERY_LOW_THRESHOLD" ]]; then
                # Constraint: Must be > Critical
                limit_val=$(get_cached_int "BATTERY_CRITICAL_THRESHOLD" 10)
                if (( min <= limit_val )); then min=$(( limit_val + 1 )); fi
                
                # Constraint: Must be < Full
                limit_val=$(get_cached_int "BATTERY_FULL_THRESHOLD" 100)
                if (( max >= limit_val )); then max=$(( limit_val - 1 )); fi

            elif [[ "$key" == "BATTERY_CRITICAL_THRESHOLD" ]]; then
                # Constraint: Must be < Low
                limit_val=$(get_cached_int "BATTERY_LOW_THRESHOLD" 20)
                if (( max >= limit_val )); then max=$(( limit_val - 1 )); fi

            elif [[ "$key" == "BATTERY_FULL_THRESHOLD" ]]; then
                # Constraint: Must be > Low
                limit_val=$(get_cached_int "BATTERY_LOW_THRESHOLD" 20)
                if (( min <= limit_val )); then min=$(( limit_val + 1 )); fi
            fi
            # -------------------------------------

            if [[ ! $current =~ ^-?[0-9]+$ ]]; then current=${min:-0}; fi
            local -i int_step=${step:-1} int_val=$current
            local -i attempt_val=$(( int_val + (direction * int_step) ))

            # Calculate actual new value clamped to limits
            if [[ -n $min ]] && (( attempt_val < min )); then 
                new_val=$min
                # Only show warning if we were actually trying to move past it
                if (( direction < 0 )); then
                    STATUS_MSG="${C_YELLOW}⚠ Limit reached: Value cannot go lower than ${min}${C_RESET}"
                fi
            elif [[ -n $max ]] && (( attempt_val > max )); then 
                new_val=$max
                if (( direction > 0 )); then
                    STATUS_MSG="${C_YELLOW}⚠ Limit reached: Value cannot go higher than ${max}${C_RESET}"
                fi
            else
                new_val=$attempt_val
            fi
            ;;
        cycle)
            local -a opts
            IFS=',' read -r -a opts <<< "$min"
            local -i count=${#opts[@]} idx=0 i
            (( count == 0 )) && return 0
            for (( i = 0; i < count; i++ )); do
                if [[ "${opts[i]}" == "$current" ]]; then idx=$i; break; fi
            done
            (( idx += direction )) || :
            (( idx < 0 )) && idx=$(( count - 1 ))
            (( idx >= count )) && idx=0
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
        post_write_action
    fi
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$label]}"
    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
        post_write_action
    fi
}

reset_defaults() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val
    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        [[ -n $def_val ]] && set_absolute_value "$item" "$def_val"
    done
    STATUS_MSG="${C_GREEN}✓ Defaults restored${C_RESET}"
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad
    local -i visible_start visible_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        len=${#name}
        zone_start=$current_col

        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi

        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 )) || :
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    [[ $pad_needed -gt 0 ]] && printf -v pad_buf '%*s' "$pad_needed" '' && tab_line+="${pad_buf}"
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    count=${#items_ref[@]}

    if (( count == 0 )); then
        SELECTED_ROW=0 SCROLL_OFFSET=0
    else
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
        if (( SELECTED_ROW < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$SELECTED_ROW
        elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
        fi
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
        local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
        (( max_scroll < 0 )) && max_scroll=0
        (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    for (( i = visible_start; i < visible_end; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-$UNSET_MARKER}

        case $val in
            true)              display="${C_GREEN}ON${C_RESET}" ;;
            false)             display="${C_RED}OFF${C_RESET}" ;;
            "$UNSET_MARKER")   display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            *)                 display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:$ITEM_PADDING}"

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    local -i rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    if (( count > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    
    # Status Message Area
    if [[ -n "$STATUS_MSG" ]]; then
        buf+="${STATUS_MSG}${CLR_EOL}"
    else
        buf+="${C_CYAN} Config: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}"
    fi
    buf+="${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

clear_status() {
    STATUS_MSG=""
}

navigate() {
    clear_status
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir )) || :
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
    return 0
}

navigate_page() {
    clear_status
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir * MAX_DISPLAY_ROWS )) || :
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
    return 0
}

navigate_end() {
    clear_status
    local -i target=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    (( count == 0 )) && return 0
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
}

adjust() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    (( ${#items_ref[@]} == 0 )) && return 0
    modify_value "${items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    clear_status
    local -i dir=${1:-1}
    (( CURRENT_TAB += dir )) || :
    (( CURRENT_TAB >= TAB_COUNT )) && CURRENT_TAB=0
    (( CURRENT_TAB < 0 )) && CURRENT_TAB=$(( TAB_COUNT - 1 ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    clear_status
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end
    local regex='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'

    if [[ $input =~ $regex ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}

        if (( button == 64 )); then
            navigate -1
            return 0
        elif (( button == 65 )); then
            navigate 1
            return 0
        fi

        [[ $type != "M" ]] && return 0

        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}
                start=${zone%%:*}
                end=${zone##*:}
                if (( x >= start && x <= end )); then set_tab "$i"; return 0; fi
            done
        fi

        local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#items_ref[@]}
        local -i item_row_start=$(( ITEM_START_ROW + 1 ))

        if (( y >= item_row_start && y < item_row_start + MAX_DISPLAY_ROWS )); then
            local -i clicked_idx=$(( y - item_row_start + SCROLL_OFFSET ))
            if (( clicked_idx >= 0 && clicked_idx < count )); then
                SELECTED_ROW=$clicked_idx
                if (( x > ADJUST_THRESHOLD )); then
                    (( button == 0 )) && adjust 1 || adjust -1
                fi
            fi
        fi
    fi
}

# --- Main ---

main() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        printf '%s[FATAL]%s Bash 4.3+ required (found %s)\n' "$C_RED" "$C_RESET" "$BASH_VERSION" >&2
        exit 1
    fi

    if [[ ! -f $CONFIG_FILE ]]; then
        log_err "Target script not found: $CONFIG_FILE"
        exit 1
    fi
    if [[ ! -w $CONFIG_FILE ]]; then
        log_err "Target script not writable: $CONFIG_FILE"
        exit 1
    fi

    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }
    command -v grep &>/dev/null || { log_err "Required: grep"; exit 1; }

    register_items
    populate_config_cache

    if command -v stty &>/dev/null; then
        ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    fi

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_tab_values

    local key seq char

    while true; do
        draw_ui
        IFS= read -rsn1 key || break

        if [[ $key == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do seq+="$char"; done
            case $seq in
                '[Z')          switch_tab -1 ;;
                '[A'|'OA')     navigate -1 ;;
                '[B'|'OB')     navigate 1 ;;
                '[C'|'OC')     adjust 1 ;;
                '[D'|'OD')     adjust -1 ;;
                '[5~')         navigate_page -1 ;;
                '[6~')         navigate_page 1 ;;
                '[H'|'[1~')    navigate_end 0 ;;
                '[F'|'[4~')    navigate_end 1 ;;
                '['*'<'*)      handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                l|L)           adjust 1 ;;
                h|H)           adjust -1 ;;
                g)             navigate_end 0 ;;
                G)             navigate_end 1 ;;
                $'\t')         switch_tab 1 ;;
                r|R)           reset_defaults ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done
}

main "$@"
