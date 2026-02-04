#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky TUI Engine - Hypridle Edition (v3.2-Consistent)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Hypridle
# Description: Specialized TUI for managing Hypridle listeners.
#              v3.2 Changes:
#              - UI Dimensions synced with Master Template v2.6.2 (Wider/Taller).
#              - Preserves v3.1 "Bulletproof" systemd logic.
# -----------------------------------------------------------------------------

set -euo pipefail

# Force standard C locale to prevent "Comma Bomb" in awk/sed
export LC_NUMERIC=C

# =============================================================================
# ▼ USER CONFIGURATION ▼
# =============================================================================

readonly CONFIG_FILE="${HOME}/.config/hypr/hypridle.conf"
readonly APP_TITLE="Dusky Hypridle"
readonly APP_VERSION="v3.2"

# Dimensions (Synced with Template v2.6.2)
declare -ri MAX_DISPLAY_ROWS=14      # Increased from 10 to 14
declare -ri BOX_INNER_WIDTH=76       # Increased from 70 to 76
declare -ri ITEM_START_ROW=5
declare -ri ADJUST_THRESHOLD=40      # Increased from 35 to 40
declare -ri ITEM_PADDING=32          # Increased from 30 to 32

readonly -a TABS=("Power States" "Warnings")

# Item Registration
register_items() {
    # --- Tab 0: Power States (The Important Stuff) ---
    register 0 "1. Auto Lock (s)"     'timeout|int|listener:3|30|7200|30'  "300"
    register 0 "2. Screen Off (s)"    'timeout|int|listener:4|30|7200|30'  "330"
    register 0 "3. Suspend (s)"       'timeout|int|listener:5|60|14400|60' "600"

    # --- Tab 1: Warnings (The Minor Stuff) ---
    register 1 "4. Kbd Backlight (s)" 'timeout|int|listener:1|10|3600|10'  "140"
    register 1 "5. Screen Dim (s)"    'timeout|int|listener:2|10|3600|10'  "150"
}

# =============================================================================
# ▲ END USER CONFIGURATION ▲
# =============================================================================

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -i DIRTY_STATE=0  # 1 = Changes made, restart needed on exit
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

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

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=()

# --- System Helpers ---

log_err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    [[ -n "${ORIGINAL_STTY:-}" ]] && stty "$ORIGINAL_STTY" 2>/dev/null || :
    printf '\n'

    # [CRITICAL LOGIC] Bulletproof Reload Strategy
    if (( DIRTY_STATE == 1 )); then
        printf "%s[INFO]%s Changes detected. Restarting hypridle...\n" "$C_CYAN" "$C_RESET"
        
        # 1. ALWAYS clear the failure counter first. This fixes "start-limit-hit".
        systemctl --user reset-failed hypridle.service 2>/dev/null || :

        # 2. Kill any manual instances to prevent duplicates
        killall hypridle 2>/dev/null || :

        # 3. Attempt Systemd Restart
        if systemctl --user restart hypridle.service 2>/dev/null; then
            # Verify it actually stayed up (sometimes it crashes immediately)
            sleep 0.2
            if systemctl --user is-active --quiet hypridle.service; then
                printf "%s[OK]%s Service restarted successfully.\n" "$C_GREEN" "$C_RESET"
                return
            fi
        fi

        # 4. SAFETY NET: If we reached here, Systemd failed (limit hit or other error).
        # We manually launch the binary so the user is not left unprotected.
        printf "%s[WARN]%s Systemd refused start. Falling back to manual process...\n" "$C_YELLOW" "$C_RESET"
        
        # Reset failed again just in case
        systemctl --user reset-failed hypridle.service 2>/dev/null || :
        
        # Launch manual instance in background, silenced
        if hypridle >/dev/null 2>&1 & disown; then
             printf "%s[OK]%s Manual fallback active.\n" "$C_GREEN" "$C_RESET"
        else
             printf "%s[FAIL]%s Could not start hypridle manually.\n" "$C_RED" "$C_RESET"
        fi
    fi
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

# --- Core Engine ---

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

# Parser
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
                block_raw = substr(line, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_raw)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", block_raw)
                
                block_counts[block_raw]++
                current_block_id = block_raw ":" block_counts[block_raw]
                
                depth++
                block_stack[depth] = current_block_id
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

# Writer
write_value_to_file() {
    local key=$1 new_val=$2 block_ref=${3:-}
    local current_val=${CONFIG_CACHE["$key|$block_ref"]:-}
    
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val safe_key
    escape_sed_replacement "$new_val" safe_val
    escape_sed_pattern "$key" safe_key

    if [[ -n $block_ref ]]; then
        local block_name=${block_ref%%:*}
        local -i target_idx=${block_ref##*:}
        [[ "$target_idx" == "$block_name" ]] && target_idx=1

        local safe_block
        escape_sed_pattern "$block_name" safe_block
        
        local line_num block_start block_end found=0
        local -i current_idx=0

        while IFS=: read -r line_num _; do
            (( current_idx++ ))
            if (( current_idx != target_idx )); then continue; fi

            block_start=$line_num
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
            
            sed --follow-symlinks -i \
                "${block_start},${real_end}s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val}|" \
                "$CONFIG_FILE"
            found=1
            break
        done < <(grep -n "^[[:space:]]*${safe_block}[[:space:]]*{" "$CONFIG_FILE")
        
        (( found == 0 )) && return 1
    else
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val}|" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block_ref"]=$new_val
    return 0
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        val=${CONFIG_CACHE["$key|$block"]:-}
        if [[ -z $val ]]; then VALUE_CACHE["$item"]=$UNSET_MARKER; else VALUE_CACHE["$item"]=$val; fi
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
            if [[ ! $current =~ ^-?[0-9]+$ ]]; then current=${min:-0}; fi
            local -i int_step=${step:-1} int_val=$current
            (( int_val += direction * int_step )) || :
            if [[ -n $min ]] && (( int_val < min )); then int_val=$min; fi
            if [[ -n $max ]] && (( int_val > max )); then int_val=$max; fi
            new_val=$int_val
            ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
        DIRTY_STATE=1
    fi
}

reset_defaults() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val key type block
    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        if [[ -n $def_val ]]; then
            if write_value_to_file "$key" "$def_val" "$block"; then
                 VALUE_CACHE["$item"]=$def_val
                 DIRTY_STATE=1
            fi
        fi
    done
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad visible_start visible_end

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
    if (( pad_needed > 0 )); then printf -v pad_buf '%*s' "$pad_needed" ''; tab_line+="${pad_buf}"; fi
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
        if (( SELECTED_ROW < SCROLL_OFFSET )); then SCROLL_OFFSET=$SELECTED_ROW; fi
        if (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 )); fi
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    if (( SCROLL_OFFSET > 0 )); then buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'; else buf+="${CLR_EOL}"$'\n'; fi

    for (( i = visible_start; i < visible_end; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-$UNSET_MARKER}
        
        case $val in
            "$UNSET_MARKER") display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            *)               display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:$ITEM_PADDING}"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    local -i rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do buf+="${CLR_EOL}"$'\n'; done

    if (( count > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        if (( visible_end < count )); then buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'; else buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'; fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→] Adjust  [↑/↓] Nav  [q] Quit${C_RESET}"$'\n'
    
    # Visual Dirty Indicator
    if (( DIRTY_STATE == 1 )); then
        buf+="${C_YELLOW} ● Pending Restart${C_RESET}${CLR_EOL}${CLR_EOS}"
    else
        buf+="${C_GREY} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    fi
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
    SELECTED_ROW=0; SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx; SELECTED_ROW=0; SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end
    local regex='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'
    if [[ $input =~ $regex ]]; then
        button=${BASH_REMATCH[1]}; x=${BASH_REMATCH[2]}; y=${BASH_REMATCH[3]}; type=${BASH_REMATCH[4]}
        if (( button == 64 )); then navigate -1; return 0; elif (( button == 65 )); then navigate 1; return 0; fi
        [[ $type != "M" ]] && return 0
        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}; start=${zone%%:*}; end=${zone##*:}
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
                if (( x > ADJUST_THRESHOLD )); then (( button == 0 )) && adjust 1 || adjust -1; fi
            fi
        fi
    fi
}

# --- Main ---

main() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        log_err "Bash 4.3+ required"; exit 1
    fi

    if [[ ! -d $(dirname "$CONFIG_FILE") ]]; then mkdir -p "$(dirname "$CONFIG_FILE")"; fi

    if [[ ! -f $CONFIG_FILE ]]; then
         log_err "Config file not found at $CONFIG_FILE"
         log_err "Please ensure hypridle is installed and config is generated."
         exit 1
    fi

    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }

    # Resurrect any dead service on startup
    if systemctl --user is-failed --quiet hypridle.service; then
        systemctl --user reset-failed hypridle.service
    fi

    register_items
    populate_config_cache
    if command -v stty &>/dev/null; then ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""; fi

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
                '[5~')         navigate -5 ;;
                '[6~')         navigate 5 ;;
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
