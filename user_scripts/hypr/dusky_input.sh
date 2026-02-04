#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Input - Refactored v5.2.3
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM
# Description: Tabbed TUI to modify input.conf.
# Base Engine: Dusky TUI Template v2.6.1
#
# Changelog v5.2.3:
#   - CRITICAL FIX: Fixed `Maps` crash caused by `set -e` and arithmetic false.
#   - FIX: Added explicit `return 0` to navigation functions to prevent exit traps.
# -----------------------------------------------------------------------------

set -euo pipefail

# CRITICAL FIX: The "Locale Bomb"
# Force standard C locale for numeric operations to prevent comma decimals (0,5).
export LC_NUMERIC=C

# --- Configuration ---
readonly CONFIG_FILE="${HOME}/.config/hypr/edit_here/source/input.conf"
readonly APP_TITLE="Dusky Input"
readonly APP_VERSION="v5.2.3"

# UI Layout Constants
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_START_ROW=5
declare -ri ADJUST_THRESHOLD=40
declare -ri ITEM_PADDING=32

# Timeout for reading escape sequences (in seconds)
readonly ESC_READ_TIMEOUT=0.02

# Internal marker for unset values
readonly UNSET_MARKER='«unset»'

# --- Pre-computed Constants ---
declare _H_LINE_BUF
printf -v _H_LINE_BUF '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE=${_H_LINE_BUF// /─}

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

# --- State ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
readonly -a TABS=("Keyboard" "Mouse" "Touchpad" "Cursor" "Gestures")
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()
# Provisioned Tab Containers (0-9)
# shellcheck disable=SC2034
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()

# --- Helpers ---

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

# Escape special characters for sed REPLACEMENT string
escape_sed_replacement() {
    local -n __out=$2
    local _s=$1
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}
    _s=${_s//&/\\&}
    _s=${_s//$'\n'/\\n}
    __out=$_s
}

# Escape special characters for sed PATTERN (Basic Regex)
escape_sed_pattern() {
    local -n __out=$2
    local _s=$1
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}
    _s=${_s//./\\.}
    _s=${_s//\*/\\*}
    _s=${_s//\[/\\[}
    _s=${_s//^/\\^}
    _s=${_s//\$/\\\$}
    _s=${_s//-/\\-}
    __out=$_s
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Registration ---

register() {
    local -i tab_idx=$1
    local label=$2 config=$3 default_val=${4:-}

    # Type Safety Validation
    local key type block min max step
    IFS='|' read -r key type block min max step <<< "$config"

    case "$type" in
        bool|int|float|cycle) ;;
        *)
            printf '%s[FATAL]%s Invalid type "%s" for "%s"\n' "$C_RED" "$C_RESET" "$type" "$label" >&2
            exit 1
            ;;
    esac

    if (( tab_idx < 0 || tab_idx >= TAB_COUNT )); then
        printf '%s[FATAL]%s Invalid tab index %d for "%s"\n' "$C_RED" "$C_RESET" "$tab_idx" "$label" >&2
        exit 1
    fi

    ITEM_MAP["$label"]=$config
    
    # Unified Defaults Handling
    if [[ -n "$default_val" ]]; then
        DEFAULTS["$label"]=$default_val
    fi

    local -n tab_ref="TAB_ITEMS_${tab_idx}"
    tab_ref+=("$label")
}

# =============================================================================
# ▼ CONFIGURATION DEFINITIONS ▼
# =============================================================================
# Syntax: register <tab_idx> "Label" "config_str" "DEFAULT_VALUE"
# config_str: "key|type|block|min|max|step"

init_items() {
    # Tab 0: Keyboard (Block: 'input')
    register 0 "Layout"             "kb_layout|cycle|input|us,uk,de,fr,es|us|" "us"
    register 0 "Numlock Default"    "numlock_by_default|bool|input|||"          "true"
    register 0 "Repeat Rate"        "repeat_rate|int|input|10|100|5"            "35"
    register 0 "Repeat Delay"       "repeat_delay|int|input|100|1000|50"        "250"
    register 0 "Resolve Binds Sym"  "resolve_binds_by_sym|bool|input|||"        "false"

    # Tab 1: Mouse (Block: 'input')
    register 1 "Sensitivity"        "sensitivity|float|input|-1.0|1.0|0.1"      "0"
    register 1 "Accel Profile"      "accel_profile|cycle|input|flat,adaptive,custom|adaptive|" "adaptive"
    register 1 "Force No Accel"     "force_no_accel|bool|input|||"              "false"
    register 1 "Left Handed"        "left_handed|bool|input|||"                 "false"
    register 1 "Follow Mouse"       "follow_mouse|int|input|0|3|1"              "1"
    register 1 "Mouse Refocus"      "mouse_refocus|bool|input|||"               "true"
    register 1 "Mouse Nat Scroll"   "natural_scroll|bool|input|||"              "false"
    register 1 "Scroll Method"      "scroll_method|cycle|input|2fg,edge,on_button_down,no_scroll|2fg|" "2fg"

    # Tab 2: Touchpad (Block: 'touchpad')
    register 2 "TP Nat Scroll"      "natural_scroll|bool|touchpad|||"           "true"
    register 2 "Tap to Click"       "tap-to-click|bool|touchpad|||"             "true"
    register 2 "Disable While Typing" "disable_while_typing|bool|touchpad|||"   "true"
    register 2 "Clickfinger Behav"  "clickfinger_behavior|bool|touchpad|||"     "false"
    register 2 "Drag Lock"          "drag_lock|bool|touchpad|||"                "false"

    # Tab 3: Cursor (Block: 'cursor')
    register 3 "No HW Cursors"      "no_hardware_cursors|int|cursor|0|2|1"      "2"
    register 3 "Use CPU Buffer"     "use_cpu_buffer|int|cursor|0|2|1"           "2"
    register 3 "Hide On Key"        "hide_on_key_press|bool|cursor|||"          "false"
    register 3 "Inactive Timeout"   "inactive_timeout|int|cursor|0|60|5"        "0"
    register 3 "Warp On Change"     "warp_on_change_workspace|int|cursor|0|2|1" "0"
    register 3 "No Break VRR"       "no_break_fs_vrr|int|cursor|0|2|1"          "2"
    register 3 "Zoom Factor"        "zoom_factor|float|cursor|1.0|5.0|0.1"      "1.0"

    # Tab 4: Gestures (Block: 'gestures')
    register 4 "Swipe Distance"     "workspace_swipe_distance|int|gestures|100|1000|50" "300"
    register 4 "Swipe Cancel Ratio" "workspace_swipe_cancel_ratio|float|gestures|0.0|1.0|0.1" "0.5"
    register 4 "Swipe Invert"       "workspace_swipe_invert|bool|gestures|||"   "true"
    register 4 "Swipe Create New"   "workspace_swipe_create_new|bool|gestures|||" "true"
    register 4 "Swipe Forever"      "workspace_swipe_forever|bool|gestures|||"  "false"
}
# =============================================================================

# --- Core Logic ---

populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part || [[ -n $key_part ]]; do
        [[ -z $key_part ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part

        key_name=${key_part%%|*}
        if [[ -z ${CONFIG_CACHE["$key_name|"]:-} ]]; then
            CONFIG_CACHE["$key_name|"]=$value_part
        fi
    done < <(awk '
        BEGIN { depth = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/#.*/, "", line)

            if (match(line, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_str = substr(line, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_str)
                depth++
                block_stack[depth] = block_str
            }

            if (line ~ /=/) {
                eq_pos = index(line, "=")
                if (eq_pos > 0) {
                    key = substr(line, 1, eq_pos - 1)
                    val = substr(line, eq_pos + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }

            n = gsub(/\}/, "}", line)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
    ' "$CONFIG_FILE")
}

write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local current_val=${CONFIG_CACHE["$key|$block"]:-}
    
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val safe_key
    escape_sed_replacement "$new_val" safe_val
    escape_sed_pattern "$key" safe_key

    if [[ -n $block ]]; then
        local safe_block
        escape_sed_pattern "$block" safe_block
        
        # CRITICAL FIX: Iterate through ALL block instances (Fixes "First Block Trap")
        local line_num block_start block_end found=0
        
        while IFS=: read -r line_num _; do
            block_start=$line_num
            
            # CRITICAL FIX: Proper brace counting for nested blocks (Fixes "Range Trap")
            block_end=$(tail -n "+${block_start}" "$CONFIG_FILE" | awk '
                BEGIN { depth = 0; started = 0 }
                {
                    txt = $0
                    sub(/#.*/, "", txt)
                    n_open = gsub(/{/, "&", txt)
                    n_close = gsub(/}/, "&", txt)
                    if (NR == 1) { depth = n_open; started = 1 } 
                    else { depth += n_open - n_close }
                    if (started && depth <= 0) { print NR; exit }
                }
            ')
            
            [[ -z $block_end ]] && continue
            
            local -i real_end=$(( block_start + block_end - 1 ))
            
            if sed -n "${block_start},${real_end}p" "$CONFIG_FILE" | \
               grep -q "^[[:space:]]*${safe_key}[[:space:]]*="; then
                
                sed --follow-symlinks -i \
                    "${block_start},${real_end}s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val} |" \
                    "$CONFIG_FILE"
                found=1
                break
            fi
        done < <(grep -n "^[[:space:]]*${safe_block}[[:space:]]*{" "$CONFIG_FILE")
        
        if (( found == 0 )); then
            return 1
        fi
    else
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val} |" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block"]=$new_val
    [[ -z $block ]] && CONFIG_CACHE["$key|"]=$new_val
    return 0
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        
        val=${CONFIG_CACHE["$key|$block"]:-}
        if [[ -z $val && -z $block ]]; then
            val=${CONFIG_CACHE["$key|"]:-}
        fi
        
        if [[ -z $val ]]; then
            VALUE_CACHE["$item"]=$UNSET_MARKER
        else
            VALUE_CACHE["$item"]=$val
        fi
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP[$label]}"
    current=${VALUE_CACHE[$label]:-}
    
    if [[ $current == "$UNSET_MARKER" || -z $current ]]; then
        current=${DEFAULTS[$label]:-}
        [[ -z $current ]] && current=${min:-0}
    fi

    case $type in
        int)
            [[ ! $current =~ ^-?[0-9]+$ ]] && current=${min:-0}
            local -i int_step=${step:-1} int_val=$current
            (( int_val += direction * int_step )) || :
            if [[ -n $min ]] && (( int_val < min )); then int_val=$min; fi
            if [[ -n $max ]] && (( int_val > max )); then int_val=$max; fi
            new_val=$int_val
            ;;
        float)
            [[ ! $current =~ ^-?[0-9]*\.?[0-9]+$ ]] && current=${min:-0.0}
            new_val=$(awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" 'BEGIN {
                val = c + (dir * s)
                if (mn != "" && val < mn) val = mn
                if (mx != "" && val > mx) val = mx
                printf "%.4g", val
            }')
            ;;
        bool)
            [[ $current == "true" ]] && new_val="false" || new_val="true"
            ;;
        cycle)
            local options_str=$min
            IFS=',' read -r -a opts <<< "$options_str"
            local -i idx=0 found=0 count=${#opts[@]}
            
            for (( i=0; i<count; i++ )); do
                if [[ "${opts[i]}" == "$current" ]]; then
                    idx=$i; found=1; break;
                fi
            done
            
            [[ $found -eq 0 ]] && idx=0
            (( idx += direction )) || :
            (( idx < 0 )) && idx=$(( count - 1 ))
            (( idx >= count )) && idx=0
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
    fi
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$label]}"
    
    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
    fi
}

reset_defaults() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val
    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        [[ -n $def_val ]] && set_absolute_value "$item" "$def_val"
    done
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
    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    count=${#items_ref[@]}

    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
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
            true)             display="${C_GREEN}ON${C_RESET}" ;;
            false)            display="${C_RED}OFF${C_RESET}" ;;
            "$UNSET_MARKER")  display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            *'$'*)            display="${C_MAGENTA}Dynamic${C_RESET}" ;;
            *)                display="${C_WHITE}${val}${C_RESET}" ;;
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
        if (( visible_end < count )); then
            buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        else
            buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir )) || :
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
    
    # CRITICAL FIX: Ensure function returns 0 (Success)
    # Without this, if the last check evaluates to false (exit code 1),
    # 'set -e' will kill the entire script.
    return 0
}

adjust() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    (( ${#items_ref[@]} == 0 )) && return 0
    modify_value "${items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}
    (( CURRENT_TAB += dir )) || :
    (( CURRENT_TAB >= TAB_COUNT )) && CURRENT_TAB=0
    (( CURRENT_TAB < 0 )) && CURRENT_TAB=$(( TAB_COUNT - 1 ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0; SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end

    # CRITICAL FIX: Move regex to variable to avoid Bash parsing errors with '<'
    local regex='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'

    if [[ $input =~ $regex ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}

        if (( button == 64 )); then navigate -1; return 0; fi
        if (( button == 65 )); then navigate 1; return 0; fi

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
        printf '%s[FATAL]%s Bash 4.3+ required\n' "$C_RED" "$C_RESET" >&2
        exit 1
    fi

    # 1. Config Validation
    if [[ ! -f $CONFIG_FILE ]]; then log_err "Config not found: $CONFIG_FILE"; exit 1; fi
    [[ ! -r $CONFIG_FILE ]] && { log_err "Config not readable"; exit 1; }
    [[ ! -w $CONFIG_FILE ]] && { log_err "Config not writable"; exit 1; }

    # 2. Initialization
    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }
    
    init_items
    populate_config_cache

    if command -v stty &>/dev/null; then
        ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    fi

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_tab_values

    local key seq char

    # 3. Event Loop
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
                '['*'<'*)      handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                l|L)           adjust 1 ;;
                h|H)           adjust -1 ;;
                $'\t')         switch_tab 1 ;;
                r|R)           reset_defaults ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done
}

main "$@"
