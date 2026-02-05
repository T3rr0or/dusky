#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Git Checker & TUI Viewer (v4.0 - Hardened)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / Bare Git Repo
# Requires: Bash 5.0+, git
# Optional: notify-send (for background notifications)
# -----------------------------------------------------------------------------

set -euo pipefail

# Force predictable locale for numeric and sorting operations
export LC_NUMERIC=C LC_COLLATE=C

# =============================================================================
# CONFIGURATION
# =============================================================================

declare -r  GIT_DIR="${HOME}/dusky/"
declare -r  WORK_TREE="${HOME}"
declare -r  STATE_FILE="${HOME}/.config/dusky/settings/dusky_update_behind_commit"
declare -r  STATE_DIR="${STATE_FILE%/*}"
declare -ri NOTIFY_THRESHOLD=30
declare -ri TIMEOUT_SEC=10

# TUI Geometry
declare -r  APP_TITLE="Dusky Updates"
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_PADDING=14
# Header layout: border(1) + title(1) + stats(1) + border(1) + scroll-hint(1) = 5 rows
declare -ri ITEM_START_ROW=5

# =============================================================================
# GIT WRAPPER
# =============================================================================

git_dusky() {
    /usr/bin/git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" "$@"
}

# =============================================================================
# BACKGROUND MODE (--num)
# =============================================================================

run_background_check() {
    [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"

    if ! timeout "$TIMEOUT_SEC" git_dusky fetch -q origin 2>/dev/null; then
        [[ -f "$STATE_FILE" ]] || printf '0\n' >"$STATE_FILE"
        exit 0
    fi

    local -i count=0
    count=$(git_dusky rev-list --count HEAD..@{u} 2>/dev/null) || count=0
    printf '%d\n' "$count" >"$STATE_FILE"

    if (( count >= NOTIFY_THRESHOLD )) && command -v notify-send &>/dev/null; then
        notify-send -u critical -t 10000 \
            "Dusky Dotfiles" \
            "Update Critical: Your system is ${count} commits behind."
    fi
    exit 0
}

[[ "${1:-}" == "--num" ]] && run_background_check

# =============================================================================
# ANSI SEQUENCES
# =============================================================================

declare _hbuf
printf -v _hbuf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_hbuf// /─}"
unset _hbuf

declare -r C_RESET=$'\e[0m'    C_CYAN=$'\e[1;36m'   C_GREEN=$'\e[1;32m'
declare -r C_YELLOW=$'\e[1;33m' C_MAGENTA=$'\e[1;35m' C_WHITE=$'\e[1;37m'
declare -r C_GREY=$'\e[1;30m'   C_INVERSE=$'\e[7m'

declare -r CLR_EOL=$'\e[K'      CLR_EOS=$'\e[J'       CLR_SCREEN=$'\e[2J'
declare -r CUR_HOME=$'\e[H'     CUR_HIDE=$'\e[?25l'   CUR_SHOW=$'\e[?25h'
declare -r MOUSE_ON=$'\e[?1000h\e[?1002h\e[?1006h'
declare -r MOUSE_OFF=$'\e[?1000l\e[?1002l\e[?1006l'

# =============================================================================
# STATE
# =============================================================================

declare -i SELECTED_ROW=0 SCROLL_OFFSET=0
declare -i TOTAL_COMMITS=0 LOCAL_REV=0 REMOTE_REV=0
declare -a COMMIT_HASHES=() COMMIT_MSGS=()
declare    ORIGINAL_STTY=""

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
    printf '%s%s%s\n' "$MOUSE_OFF" "$CUR_SHOW" "$C_RESET"
    [[ -n "${ORIGINAL_STTY:-}" ]] && stty "$ORIGINAL_STTY" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# =============================================================================
# DATA LOADING
# =============================================================================

load_commits() {
    COMMIT_HASHES=() COMMIT_MSGS=()
    
    local -i count=0
    count=$(git_dusky rev-list --count HEAD..@{u} 2>/dev/null) || count=0
    LOCAL_REV=$(git_dusky rev-list --count HEAD 2>/dev/null)   || LOCAL_REV=0
    REMOTE_REV=$(git_dusky rev-list --count @{u} 2>/dev/null)  || REMOTE_REV=0

    if (( count == 0 )); then
        COMMIT_HASHES=("HEAD")
        COMMIT_MSGS=("Dusky is up to date!")
        TOTAL_COMMITS=1
        return 0
    fi

    local -ri max_len=$(( BOX_INNER_WIDTH - ITEM_PADDING - 6 ))
    local hash msg

    while IFS='|' read -r hash msg; do
        [[ -z $hash ]] && continue
        COMMIT_HASHES+=("$hash")
        (( ${#msg} > max_len )) && msg="${msg:0:max_len-1}…"
        COMMIT_MSGS+=("$msg")
    done < <(git_dusky log HEAD..@{u} --pretty=format:'%h|%s' 2>/dev/null)

    TOTAL_COMMITS=${#COMMIT_HASHES[@]}

    # Fallback if git log failed after count succeeded
    if (( TOTAL_COMMITS == 0 )); then
        COMMIT_HASHES=("ERR")
        COMMIT_MSGS=("Failed to retrieve commit list")
        TOTAL_COMMITS=1
    fi
}

# =============================================================================
# RENDERING
# =============================================================================

draw_ui() {
    local buf="" pad=""
    local -i vlen lpad rpad vstart vend i

    buf+="$CUR_HOME"

    # ── Header Box ──
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    # Title with revision info
    local raw="${APP_TITLE} Local: #${LOCAL_REV} vs Remote: #${REMOTE_REV}"
    vlen=${#raw}
    lpad=$(( (BOX_INNER_WIDTH - vlen) / 2 ))
    rpad=$(( BOX_INNER_WIDTH - vlen - lpad ))
    printf -v pad '%*s' "$lpad" ''
    buf+="${C_MAGENTA}│${pad}${C_WHITE}${APP_TITLE} ${C_GREY}Local: #${LOCAL_REV} vs Remote: #${REMOTE_REV}${C_WHITE}"
    printf -v pad '%*s' "$rpad" ''
    buf+="${pad}${C_MAGENTA}│${C_RESET}"$'\n'

    # Status line
    local stats="Commits Behind: ${TOTAL_COMMITS}"
    [[ ${COMMIT_HASHES[0]} == "HEAD" ]] && stats="Status: Up to date"
    [[ ${COMMIT_HASHES[0]} == "ERR" ]]  && stats="Status: Load error"
    printf -v pad '%*s' "$(( BOX_INNER_WIDTH - ${#stats} - 1 ))" ''
    buf+="${C_MAGENTA}│ ${C_GREEN}${stats}${pad}${C_MAGENTA}│${C_RESET}"$'\n'

    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # ── Scroll bounds ──
    if (( TOTAL_COMMITS > 0 )); then
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= TOTAL_COMMITS )) && SELECTED_ROW=$(( TOTAL_COMMITS - 1 ))
        (( SELECTED_ROW < SCROLL_OFFSET )) && SCROLL_OFFSET=$SELECTED_ROW
        (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )) && \
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    else
        SELECTED_ROW=0 SCROLL_OFFSET=0
    fi

    vstart=$SCROLL_OFFSET
    vend=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( vend > TOTAL_COMMITS )) && vend=$TOTAL_COMMITS

    # Scroll indicator (above)
    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # ── List items ──
    for (( i = vstart; i < vend; i++ )); do
        local h="${COMMIT_HASHES[i]}" m="${COMMIT_MSGS[i]}" ph
        printf -v ph "%-${ITEM_PADDING}s" "$h"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${ph}${C_RESET} : ${C_WHITE}${m}${C_RESET}${CLR_EOL}"$'\n'
        else
            buf+="    ${C_GREY}${ph}${C_RESET} : ${C_GREY}${m}${C_RESET}${CLR_EOL}"$'\n'
        fi
    done

    # Blank rows to fill viewport
    for (( i = vend - vstart; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    # Scroll indicator (below)
    if (( TOTAL_COMMITS > MAX_DISPLAY_ROWS )); then
        local pos="[$(( SELECTED_ROW + 1 ))/${TOTAL_COMMITS}]"
        if (( vend < TOTAL_COMMITS )); then
            buf+="${C_GREY}    ▼ (more below) ${pos}${CLR_EOL}${C_RESET}"$'\n'
        else
            buf+="${C_GREY}                   ${pos}${CLR_EOL}${C_RESET}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Help bar
    buf+=$'\n'"${C_CYAN} [↑↓/jk] Move  [PgUp/Dn] Page  [g/G] Start/End  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} Repo: ${C_WHITE}${GIT_DIR}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# =============================================================================
# NAVIGATION
# =============================================================================

nav_step() {
    local -i d=$1
    (( TOTAL_COMMITS == 0 )) && return 0
    # Use modulo arithmetic for infinite scrolling
    SELECTED_ROW=$(( (SELECTED_ROW + d + TOTAL_COMMITS) % TOTAL_COMMITS ))
}

nav_page() {
    local -i d=$1
    (( TOTAL_COMMITS == 0 )) && return 0
    SELECTED_ROW=$(( SELECTED_ROW + d * MAX_DISPLAY_ROWS ))
    # Clamp to bounds (no wrap on page jump)
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= TOTAL_COMMITS )) && SELECTED_ROW=$(( TOTAL_COMMITS - 1 ))
}

nav_edge() {
    (( TOTAL_COMMITS == 0 )) && return 0
    case $1 in
        home) SELECTED_ROW=0 ;;
        end)  SELECTED_ROW=$(( TOTAL_COMMITS - 1 )) ;;
    esac
}

handle_mouse() {
    local seq=$1
    # SGR mouse: [<btn;col;rowM or [<btn;col;rowm
    local re='^\[<([0-9]+);[0-9]+;([0-9]+)([Mm])$'
    [[ $seq =~ $re ]] || return 0

    local -i btn=${BASH_REMATCH[1]} row=${BASH_REMATCH[2]}
    local ev=${BASH_REMATCH[3]}

    case $btn in
        64) nav_step -1; return 0 ;;   # scroll up
        65) nav_step  1; return 0 ;;   # scroll down
    esac

    [[ $ev == M ]] || return 0  # ignore release

    local -i list_start=$(( ITEM_START_ROW + 1 ))
    if (( row >= list_start && row < list_start + MAX_DISPLAY_ROWS )); then
        local -i idx=$(( row - list_start + SCROLL_OFFSET ))
        (( idx >= 0 && idx < TOTAL_COMMITS )) && SELECTED_ROW=$idx
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    (( BASH_VERSINFO[0] >= 5 )) || {
        printf 'Error: Bash 5.0+ required (found %s)\n' "$BASH_VERSION" >&2
        exit 1
    }

    printf '\n%sFetching updates from origin...%s\n' "$C_CYAN" "$C_RESET"
    printf '%s(If prompted, enter your SSH key passphrase)%s\n\n' "$C_GREY" "$C_RESET"

    if ! timeout "$TIMEOUT_SEC" git_dusky fetch -q origin 2>/dev/null; then
        printf '%s[WARNING] Fetch failed or timed out.%s\n' "$C_YELLOW" "$C_RESET"
        sleep 2
    fi

    load_commits

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    printf '%s%s%s%s' "$MOUSE_ON" "$CUR_HIDE" "$CLR_SCREEN" "$CUR_HOME"

    local key seq ch
    while true; do
        draw_ui
        IFS= read -rsn1 key || break

        if [[ $key == $'\e' ]]; then
            seq=""
            # Increased timeout to 0.05s to prevent split escape codes on slow terminals
            while IFS= read -rsn1 -t 0.05 ch; do seq+="$ch"; done

            case $seq in
                ''       ) break ;;              # bare ESC = quit
                '[A'|OA  ) nav_step -1 ;;        # Up
                '[B'|OB  ) nav_step  1 ;;        # Down
                '[5~'    ) nav_page -1 ;;        # PgUp
                '[6~'    ) nav_page  1 ;;        # PgDn
                '[H'|'[1~') nav_edge home ;;     # Home
                '[F'|'[4~') nav_edge end ;;      # End
                '['*'<'* ) handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K      ) nav_step -1 ;;
                j|J      ) nav_step  1 ;;
                g        ) nav_edge home ;;
                G        ) nav_edge end ;;
                q|Q|$'\x03') break ;;
            esac
        fi
    done
}

main "$@"
