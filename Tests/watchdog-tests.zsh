#!/bin/zsh

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly WATCHDOG="$REPO_ROOT/Source/Watchdog/power-protect-watchdog.zsh"
readonly TEST_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/power-protect-watchdog-tests.XXXXXX")

trap '/bin/rm -rf "$TEST_ROOT"' EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected $expected, got $actual)"
}

assert_exists() {
  [[ -e "$1" ]] || fail "$2"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "$2"
}

write_config() {
  local enabled="$1"
  local percent="$2"
  local reset_inactive="${3:-true}"
  local bool="<true/>"
  local reset_bool="<true/>"
  [[ "$enabled" == "false" ]] && bool="<false/>"
  [[ "$reset_inactive" == "false" ]] && reset_bool="<false/>"

  /bin/cat > "$POWER_PROTECT_STATE_DIR/config.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Enabled</key>
    $bool
    <key>LowBatteryPercent</key>
    <integer>$percent</integer>
    <key>ResetSleepWhenInactive</key>
    $reset_bool
</dict>
</plist>
EOF
}

set_power_source() {
  local source="$1"
  local percent="$2"
  /bin/cat > "$FAKE_PMSET_BATTERY" <<EOF
Now drawing from '$source'
 -InternalBattery-0 (id=1)  ${percent}%; discharging; present: true
EOF
}

set_session() {
  local state="$1"
  if [[ "$state" == "active" ]]; then
    /bin/cat > "$FAKE_PMSET_ASSERTIONS" <<'EOF'
Listed by owning process:
   pid 123(Amphetamine): [0x1] 00:01:00 PreventUserIdleSystemSleep named: "Amphetamine (Single-Use - System)"
EOF
  else
    print -r -- "No assertions." > "$FAKE_PMSET_ASSERTIONS"
  fi
}

setup_case() {
  local name="$1"
  local initial_sleep_disabled="$2"
  local case_root="$TEST_ROOT/$name"

  export POWER_PROTECT_STATE_DIR="$case_root/state"
  export POWER_PROTECT_PMSET="$case_root/bin/pmset"
  export POWER_PROTECT_SUDO="$case_root/bin/sudo"
  export POWER_PROTECT_LOGGER="$case_root/bin/logger"
  export FAKE_PMSET_STATE="$case_root/fixtures/sleep-disabled"
  export FAKE_PMSET_CHANGES="$case_root/fixtures/changes"
  export FAKE_PMSET_ASSERTIONS="$case_root/fixtures/assertions"
  export FAKE_PMSET_BATTERY="$case_root/fixtures/battery"

  /bin/mkdir -p "$POWER_PROTECT_STATE_DIR" "$case_root/bin" "$case_root/fixtures"
  print -r -- "$initial_sleep_disabled" > "$FAKE_PMSET_STATE"

  /bin/cat > "$POWER_PROTECT_PMSET" <<'EOF'
#!/bin/zsh
case "$*" in
  "-g assertions")
    /bin/cat "$FAKE_PMSET_ASSERTIONS"
    ;;
  "-g batt")
    /bin/cat "$FAKE_PMSET_BATTERY"
    ;;
  "-g")
    print -r -- " SleepDisabled        $(<"$FAKE_PMSET_STATE")"
    ;;
  "-a disablesleep "*)
    print -r -- "$3" > "$FAKE_PMSET_STATE"
    print -r -- "$3" >> "$FAKE_PMSET_CHANGES"
    ;;
  *)
    print -u2 -- "Unexpected pmset arguments: $*"
    exit 64
    ;;
esac
EOF

  /bin/cat > "$POWER_PROTECT_SUDO" <<'EOF'
#!/bin/zsh
[[ "${1:-}" == "-n" ]] && shift
exec "$@"
EOF

  /bin/cat > "$POWER_PROTECT_LOGGER" <<'EOF'
#!/bin/zsh
exit 0
EOF

  /bin/chmod 700 "$POWER_PROTECT_PMSET" "$POWER_PROTECT_SUDO" "$POWER_PROTECT_LOGGER"
  write_config true 35
  set_session active
  set_power_source "Battery Power" 78
}

run_watchdog_once() {
  [[ -x "$WATCHDOG" ]] || fail "watchdog implementation is missing or not executable"
  "$WATCHDOG" --once
}

run_watchdog_cleanup() {
  [[ -x "$WATCHDOG" ]] || fail "watchdog implementation is missing or not executable"
  "$WATCHDOG" --cleanup
}

setup_case active_session 0
run_watchdog_once
assert_equal 1 "$(<"$FAKE_PMSET_STATE")" "active session should restore SleepDisabled"
assert_exists "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned" "active session should record ownership"

setup_case unowned_inactive 1
set_session inactive
run_watchdog_once
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "inactive helper should repair leaked SleepDisabled"

setup_case inactive_reset_opt_out 1
write_config true 35 false
set_session inactive
run_watchdog_once
assert_equal 1 "$(<"$FAKE_PMSET_STATE")" "inactive reset opt-out should preserve unowned SleepDisabled"
assert_not_exists "$FAKE_PMSET_CHANGES" "inactive reset opt-out must not call pmset for unowned state"

setup_case owned_inactive 1
/usr/bin/touch "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned"
set_session inactive
run_watchdog_once
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "inactive session should clean up owned SleepDisabled"
assert_not_exists "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned" "cleanup should remove ownership marker"

setup_case low_battery 1
/usr/bin/touch "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned"
set_power_source "Battery Power" 35
run_watchdog_once
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "low battery should restore system sleep"
assert_exists "$POWER_PROTECT_STATE_DIR/low-battery-latched" "low battery should latch until AC returns"
assert_not_exists "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned" "low battery should release ownership"

set_power_source "AC Power" 35
run_watchdog_once
assert_equal 1 "$(<"$FAKE_PMSET_STATE")" "AC power should clear the low-battery latch and re-enable protection"
assert_not_exists "$POWER_PROTECT_STATE_DIR/low-battery-latched" "AC power should clear the low-battery latch"

setup_case disabled_config 1
/usr/bin/touch "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned"
write_config false 35
run_watchdog_once
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "disabled watchdog should clean up owned SleepDisabled"

setup_case unreadable_battery 1
/usr/bin/touch "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned"
print -r -- "Battery status unavailable" > "$FAKE_PMSET_BATTERY"
run_watchdog_once
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "unreadable battery state should fail safe"
assert_not_exists "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned" "fail-safe cleanup should release ownership"

setup_case sudo_failure 0
/bin/cat > "$POWER_PROTECT_SUDO" <<'EOF'
#!/bin/zsh
exit 1
EOF
/bin/chmod 700 "$POWER_PROTECT_SUDO"
if run_watchdog_once; then
  fail "failed pmset authorization should return a failure"
fi
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "failed pmset authorization should leave system sleep enabled"
assert_not_exists "$POWER_PROTECT_STATE_DIR/sleep-disabled-owned" "failed pmset authorization must not claim ownership"

setup_case uninstall_cleanup 1
run_watchdog_cleanup
assert_equal 0 "$(<"$FAKE_PMSET_STATE")" "uninstall cleanup should repair leaked SleepDisabled"

print -r -- "PASS: Power Protect watchdog regression tests"
