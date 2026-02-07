#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Elite Mono Toggle for Arch/Hyprland (PipeWire)
# Architecture: Null Sink (1ch Mix) -> Loopback (2ch Duplicate) -> Hardware
# Features: Atomic cleanup via EXIT trap, WirePlumber Policy Override, 10ms Latency
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration -----------------------------------------------------------
readonly MONO_SINK_NAME="mono_global_downmix"
# Using XDG_RUNTIME_DIR ensures the state file is in RAM (tmpfs) and per-user
readonly STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/mono_audio_state_${UID}"
readonly INDICATOR_FILE="${HOME}/.config/dusky/settings/mono_audio"

# --- Helpers -----------------------------------------------------------------

# Write persistent state for external bars/widgets (True/False)
set_indicator_state() {
    local state="$1"
    # Ensure directory exists
    mkdir -p "$(dirname "$INDICATOR_FILE")"
    echo "$state" > "$INDICATOR_FILE"
}

# Get sink ID from sink name (Exact Match)
get_sink_id() {
    pactl list sinks short 2>/dev/null | awk -v name="$1" '$2 == name {print $1; exit}'
}

# Get sink name from sink ID (Exact Match)
get_sink_name() {
    pactl list sinks short 2>/dev/null | awk -v id="$1" '$1 == id {print $2; exit}'
}

# Poll until sink appears (Max 1s)
wait_for_sink() {
    local -i attempts=0
    while (( attempts++ < 20 )); do
        if [[ -n "$(get_sink_id "$1")" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Move active streams to target. 
move_streams() {
    local target_id
    target_id=$(get_sink_id "$1")
    [[ -n "$target_id" ]] || return 0

    local stream_id current_sink_id _rest
    while read -r stream_id current_sink_id _rest; do
        [[ -n "$stream_id" ]] || continue
        # Skip if already on target
        [[ "$current_sink_id" == "$target_id" ]] && continue
        
        pactl move-sink-input "$stream_id" "$target_id" 2>/dev/null || true
    done < <(pactl list sink-inputs short 2>/dev/null)
}

# Heuristic: Find hardware sink with the most active inputs
get_busiest_sink_id() {
    pactl list sink-inputs short 2>/dev/null | awk '
        { count[$2]++ }
        END {
            max = 0; best = ""
            for (id in count) if (count[id] > max) { max = count[id]; best = id }
            # Only print if we found a best match to avoid empty newlines
            if (best != "") print best
        }'
}

# Robust Cleanup: Single-pass parsing.
cleanup_mono_modules() {
    local mod_id mod_name mod_args
    local -a loopback_ids=() nullsink_ids=()

    # Read without IFS to preserve args in the last variable
    while read -r mod_id mod_name mod_args; do
        case "$mod_name" in
            module-loopback)
                if [[ "$mod_args" == *"source=${MONO_SINK_NAME}.monitor"* ]]; then
                    loopback_ids+=("$mod_id")
                fi
                ;;
            module-null-sink)
                if [[ "$mod_args" == *"sink_name=${MONO_SINK_NAME}"* ]]; then
                    nullsink_ids+=("$mod_id")
                fi
                ;;
        esac
    done < <(pactl list modules short 2>/dev/null)

    local id
    # Unload loopbacks
    for id in "${loopback_ids[@]}"; do
        pactl unload-module "$id" 2>/dev/null || true
    done

    # Unload null sinks
    for id in "${nullsink_ids[@]}"; do
        pactl unload-module "$id" 2>/dev/null || true
    done
}

# --- Main Logic --------------------------------------------------------------

# Check if Mono Sink exists to determine toggle state
if [[ -n "$(get_sink_id "$MONO_SINK_NAME")" ]]; then
    # =========================================================================
    # TOGGLE OFF: Restore Stereo
    # =========================================================================

    RESTORE_SINK=""
    if [[ -s "$STATE_FILE" ]]; then
        RESTORE_SINK=$(<"$STATE_FILE")
    fi

    # Fallback: Find first hardware sink that isn't our mono sink
    if [[ -z "$RESTORE_SINK" ]]; then
        RESTORE_SINK=$(pactl list sinks short 2>/dev/null \
            | awk -v mono="$MONO_SINK_NAME" '$2 != mono { print $2; exit }')
    fi

    if [[ -z "$RESTORE_SINK" ]]; then
        notify-send -u critical "Audio Error" "No hardware sink found to restore!" 2>/dev/null || true
        cleanup_mono_modules
        rm -f "$STATE_FILE"
        exit 1
    fi

    # 1. Restore Default Sink
    pactl set-default-sink "$RESTORE_SINK" 2>/dev/null || true
    
    # 2. Move active streams back to hardware
    move_streams "$RESTORE_SINK"
    
    # 3. Cleanup Modules
    cleanup_mono_modules
    
    # 4. Remove State
    rm -f "$STATE_FILE"

    # 5. Update Status Indicator
    set_indicator_state "False"

    notify-send -u low -t 2000 "Audio" "Switched to Stereo 🎧" 2>/dev/null || true

else
    # =========================================================================
    # TOGGLE ON: Enable True Mono
    # =========================================================================

    # EXIT TRAP: Catches set -e failures, SIGINT, SIGTERM, and manual exits.
    # We use a success flag to decide if we should cleanup or not on exit.
    _toggle_success=false
    trap '
        if [[ "$_toggle_success" != true ]]; then
            cleanup_mono_modules
            rm -f "$STATE_FILE"
            set_indicator_state "False"
        fi
    ' EXIT
    
    # 1. Detect Target Sink (Busiest -> Default -> Fail)
    BUSIEST_ID=$(get_busiest_sink_id)
    TARGET_SINK=""
    
    if [[ -n "$BUSIEST_ID" ]]; then
        TARGET_SINK=$(get_sink_name "$BUSIEST_ID")
    fi
    if [[ -z "$TARGET_SINK" ]]; then
        # Guarded with || true so set -e doesn't kill script if no default exists
        TARGET_SINK=$(pactl get-default-sink 2>/dev/null) || true
    fi
    if [[ -z "$TARGET_SINK" ]]; then
        notify-send -u critical "Audio Error" "No audio device found!" 2>/dev/null || true
        exit 1
    fi

    # 2. Save State
    printf '%s' "$TARGET_SINK" > "$STATE_FILE"

    # 3. Create Null Sink (Downmixer)
    if ! pactl load-module module-null-sink \
            sink_name="$MONO_SINK_NAME" \
            sink_properties='device.description="Mono_Downmix"' \
            channels=1 \
            channel_map=mono > /dev/null 2>&1; then
        notify-send -u critical "Audio Error" "Failed to create null sink." 2>/dev/null || true
        exit 1
    fi

    # 4. Wait for Sink
    if ! wait_for_sink "$MONO_SINK_NAME"; then
        notify-send -u critical "Audio Error" "Mono sink timeout." 2>/dev/null || true
        # Trap will handle cleanup
        exit 1
    fi

    # 5. Set Default Sink -> Mono
    pactl set-default-sink "$MONO_SINK_NAME"
    
    # Small yield to let WirePlumber acknowledge the default sink change
    sleep 0.1

    # 6. Move existing streams to Mono
    move_streams "$MONO_SINK_NAME"

    # 7. Create Loopback (Mono Monitor -> Hardware Sink)
    # sink_dont_move=true prevents feedback loops
    if ! pactl load-module module-loopback \
            source="${MONO_SINK_NAME}.monitor" \
            sink="$TARGET_SINK" \
            channels=2 \
            channel_map=front-left,front-right \
            sink_dont_move=true \
            source_dont_move=true \
            latency_msec=10 \
            remix=no > /dev/null 2>&1; then
        notify-send -u critical "Audio Error" "Failed to create loopback." 2>/dev/null || true
        # Trap will handle cleanup
        exit 1
    fi

    # 8. Mark Success
    _toggle_success=true
    set_indicator_state "True"

    notify-send -u low -t 2000 "Audio" "Switched to Mono 🔊" 2>/dev/null || true
fi
