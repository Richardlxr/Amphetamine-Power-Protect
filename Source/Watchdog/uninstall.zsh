#!/bin/zsh

emulate -L zsh
setopt NO_UNSET PIPE_FAIL

readonly LABEL="com.if.Amphetamine.PowerProtectWatchdog"
readonly INSTALL_DIR="$HOME/Library/Application Support/Amphetamine/Power Protect Watchdog"
readonly WATCHDOG="$INSTALL_DIR/power-protect-watchdog.zsh"
readonly LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly UID_VALUE=$(/usr/bin/id -u)

/bin/launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true

if [[ -x "$WATCHDOG" ]]; then
  "$WATCHDOG" --cleanup || {
    print -u2 -- "Warning: SleepDisabled cleanup failed. Run: sudo pmset -a disablesleep 0"
    exit 1
  }
fi

/bin/rm -f "$LAUNCH_AGENT"
/bin/rm -rf "$INSTALL_DIR"

print -r -- "Power Protect Watchdog uninstalled. The original Power Protect installation was not changed."
