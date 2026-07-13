#!/bin/zsh

emulate -L zsh
setopt NO_UNSET PIPE_FAIL
umask 077

readonly LABEL="com.if.Amphetamine.PowerProtectWatchdog"
readonly STATE_DIR="${POWER_PROTECT_STATE_DIR:-$HOME/Library/Application Support/Amphetamine/Power Protect Watchdog}"
readonly CONFIG_FILE="$STATE_DIR/config.plist"
readonly OWNED_MARKER="$STATE_DIR/sleep-disabled-owned"
readonly LOW_BATTERY_LATCH="$STATE_DIR/low-battery-latched"
readonly LOG_FILE="$STATE_DIR/activity.log"
readonly PMSET_BIN="${POWER_PROTECT_PMSET:-/usr/bin/pmset}"
readonly SUDO_BIN="${POWER_PROTECT_SUDO:-/usr/bin/sudo}"
readonly LOGGER_BIN="${POWER_PROTECT_LOGGER:-/usr/bin/logger}"
readonly POLL_SECONDS=2
readonly DEFAULT_LOW_BATTERY_PERCENT=35

/bin/mkdir -p "$STATE_DIR"

log_message() {
  local message="$1"
  print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $message" >> "$LOG_FILE"
  "$LOGGER_BIN" -t "$LABEL" -- "$message"
}

amphetamine_session_active() {
  local assertions
  assertions=$("$PMSET_BIN" -g assertions 2>/dev/null) || return 1
  /usr/bin/grep -Eq 'pid [0-9]+\(Amphetamine\):.*PreventUserIdleSystemSleep' <<< "$assertions"
}

watchdog_enabled() {
  local value
  value=$(/usr/bin/plutil -extract "Enabled" raw -o - "$CONFIG_FILE" 2>/dev/null) || return 1
  [[ "$value" == "true" ]]
}

reset_sleep_when_inactive() {
  local value
  value=$(/usr/bin/plutil -extract "ResetSleepWhenInactive" raw -o - "$CONFIG_FILE" 2>/dev/null) || value="true"
  [[ "$value" == "true" ]]
}

sleep_disabled_value() {
  "$PMSET_BIN" -g 2>/dev/null |
    /usr/bin/awk '/SleepDisabled/ { print $2 }'
}

power_source() {
  local battery_status="${1:-}"
  [[ -n "$battery_status" ]] || battery_status=$("$PMSET_BIN" -g batt 2>/dev/null)
  print -r -- "$battery_status" |
    /usr/bin/sed -n "1s/.*'\([^']*\)'.*/\1/p"
}

battery_percent() {
  local battery_status="${1:-}"
  [[ -n "$battery_status" ]] || battery_status=$("$PMSET_BIN" -g batt 2>/dev/null)
  print -r -- "$battery_status" |
    /usr/bin/sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' |
    /usr/bin/head -n 1
}

low_battery_threshold() {
  local value
  value=$(/usr/bin/plutil -extract "LowBatteryPercent" raw -o - "$CONFIG_FILE" 2>/dev/null) || value=""
  if [[ "$value" == <-> && "$value" -ge 5 && "$value" -le 95 ]]; then
    print -r -- "$value"
  else
    print -r -- "$DEFAULT_LOW_BATTERY_PERCENT"
  fi
}

set_sleep_disabled() {
  local desired="$1"
  local reason="$2"
  local current
  current=$(sleep_disabled_value)

  if [[ "$current" == "$desired" ]]; then
    return 0
  fi

  if "$SUDO_BIN" -n "$PMSET_BIN" -a disablesleep "$desired"; then
    log_message "SleepDisabled=$desired ($reason)"
    return 0
  fi

  log_message "ERROR: could not set SleepDisabled=$desired ($reason)"
  return 1
}

cleanup_owned_state() {
  local reason="$1"
  if [[ -e "$OWNED_MARKER" ]]; then
    if set_sleep_disabled 0 "$reason"; then
      /bin/rm -f "$OWNED_MARKER"
    else
      return 1
    fi
  fi
  /bin/rm -f "$LOW_BATTERY_LATCH"
}

release_sleep_override() {
  local reason="$1"
  if set_sleep_disabled 0 "$reason"; then
    /bin/rm -f "$OWNED_MARKER"
    return 0
  fi
  return 1
}

cleanup_for_exit() {
  local reason="$1"
  if watchdog_enabled && reset_sleep_when_inactive; then
    release_sleep_override "$reason"
    /bin/rm -f "$LOW_BATTERY_LATCH"
  else
    cleanup_owned_state "$reason"
  fi
}

claim_sleep_override() {
  local reason="$1"
  local marker_created="no"

  if [[ ! -e "$OWNED_MARKER" ]]; then
    if ! /usr/bin/touch "$OWNED_MARKER"; then
      log_message "ERROR: could not create ownership marker"
      return 1
    fi
    marker_created="yes"
  fi

  if set_sleep_disabled 1 "$reason"; then
    return 0
  fi

  [[ "$marker_created" == "yes" ]] && /bin/rm -f "$OWNED_MARKER"
  return 1
}

reconcile() {
  local battery_status source percent threshold

  if ! watchdog_enabled; then
    cleanup_owned_state "watchdog disabled"
    return
  fi

  if ! amphetamine_session_active; then
    if reset_sleep_when_inactive; then
      release_sleep_override "Amphetamine session inactive"
      /bin/rm -f "$LOW_BATTERY_LATCH"
    else
      cleanup_owned_state "Amphetamine session inactive"
    fi
    return
  fi

  battery_status=$("$PMSET_BIN" -g batt 2>/dev/null)
  source=$(power_source "$battery_status")
  percent=$(battery_percent "$battery_status")
  threshold=$(low_battery_threshold)

  if [[ "$source" != "AC Power" && "$source" != "Battery Power" ]] ||
     [[ "$source" == "Battery Power" && "$percent" != <-> ]]; then
    release_sleep_override "power state unavailable"
    return
  fi

  if [[ "$source" == "AC Power" ]]; then
    /bin/rm -f "$LOW_BATTERY_LATCH"
  elif [[ "$source" == "Battery Power" ]]; then
    if [[ "$percent" == <-> && "$percent" -le "$threshold" ]]; then
      if [[ ! -e "$LOW_BATTERY_LATCH" ]]; then
        log_message "Low-battery protection engaged at ${percent}% (threshold ${threshold}%)"
        /usr/bin/touch "$LOW_BATTERY_LATCH"
      fi
    fi

    if [[ -e "$LOW_BATTERY_LATCH" ]]; then
      release_sleep_override "low-battery protection"
      return
    fi
  fi

  claim_sleep_override "active Amphetamine session on $source"
}

print_status() {
  local active="no" enabled="no" reset_inactive="no" battery_status source percent
  amphetamine_session_active && active="yes"
  watchdog_enabled && enabled="yes"
  reset_sleep_when_inactive && reset_inactive="yes"
  battery_status=$("$PMSET_BIN" -g batt 2>/dev/null)
  source=$(power_source "$battery_status")
  percent=$(battery_percent "$battery_status")

  print -r -- "AmphetamineSessionActive=$active"
  print -r -- "WatchdogEnabled=$enabled"
  print -r -- "ResetSleepWhenInactive=$reset_inactive"
  print -r -- "PowerSource=$source"
  print -r -- "BatteryPercent=$percent"
  print -r -- "LowBatteryThreshold=$(low_battery_threshold)"
  print -r -- "SleepDisabled=$(sleep_disabled_value)"
  print -r -- "WatchdogOwnsState=$([[ -e "$OWNED_MARKER" ]] && print yes || print no)"
  print -r -- "LowBatteryLatched=$([[ -e "$LOW_BATTERY_LATCH" ]] && print yes || print no)"
}

case "${1:-run}" in
  run)
    trap 'cleanup_for_exit "watchdog stopped"; exit 0' TERM INT HUP
    log_message "Watchdog started"
    while true; do
      reconcile
      /bin/sleep "$POLL_SECONDS"
    done
    ;;
  --once)
    reconcile
    ;;
  --status)
    print_status
    ;;
  --cleanup)
    cleanup_for_exit "manual cleanup"
    ;;
  *)
    print -u2 -- "Usage: $0 [run|--once|--status|--cleanup]"
    exit 64
    ;;
esac
