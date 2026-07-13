#!/bin/zsh

emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 077

readonly LABEL="com.if.Amphetamine.PowerProtectWatchdog"
readonly SOURCE_DIR="${0:A:h}"
readonly INSTALL_DIR="$HOME/Library/Application Support/Amphetamine/Power Protect Watchdog"
readonly LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly UID_VALUE=$(/usr/bin/id -u)

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  print -u2 -- "Power Protect Watchdog is only intended for Apple Silicon Macs."
  exit 1
fi

if [[ ! -d "/Applications/Amphetamine.app" ]]; then
  print -u2 -- "Install Amphetamine before installing Power Protect Watchdog."
  exit 1
fi

if [[ ! -f "$HOME/Library/Application Scripts/com.if.Amphetamine/powerProtect.scpt" ]]; then
  print -u2 -- "Install Power Protect before installing its watchdog."
  exit 1
fi

if ! /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 ||
   ! /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  print -u2 -- "The installed Power Protect sudoers rule does not authorize both required pmset commands."
  exit 1
fi

/bin/launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
/bin/mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents"
/usr/bin/install -m 700 "$SOURCE_DIR/power-protect-watchdog.zsh" "$INSTALL_DIR/power-protect-watchdog.zsh"
/usr/bin/install -m 644 "$SOURCE_DIR/com.if.Amphetamine.PowerProtectWatchdog.plist" "$LAUNCH_AGENT"

if [[ ! -f "$INSTALL_DIR/config.plist" ]]; then
  /usr/bin/install -m 600 "$SOURCE_DIR/config.plist" "$INSTALL_DIR/config.plist"
fi

/usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null
/bin/launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_AGENT"
/bin/sleep 3
service_state=$(/bin/launchctl print "gui/$UID_VALUE/$LABEL" 2>/dev/null) || service_state=""

if [[ "$service_state" != *"state = running"* ]]; then
  /bin/launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  "$INSTALL_DIR/power-protect-watchdog.zsh" --cleanup || true
  print -u2 -- "Power Protect Watchdog did not remain running. See Console.app for $LABEL."
  exit 1
fi

print -r -- "Power Protect Watchdog installed."
"$INSTALL_DIR/power-protect-watchdog.zsh" --status
