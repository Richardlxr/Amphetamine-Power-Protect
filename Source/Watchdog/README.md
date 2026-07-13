# Power Protect Watchdog

Power Protect normally calls `pmset -a disablesleep 1` when Amphetamine starts a Closed-Display Mode session. On some Apple Silicon/macOS combinations, macOS resets `SleepDisabled` to `0` after the power source or external-display topology changes, but Amphetamine's session assertion remains active. The Mac can then enter `Clamshell Sleep` even though the session is still running.

This optional watchdog closes that reassertion gap. Every two seconds it checks for an Amphetamine-owned `PreventUserIdleSystemSleep` assertion. While that assertion is active, it restores `SleepDisabled=1` if macOS resets it.

## Safety behavior

- Records an ownership marker before enabling `SleepDisabled` for an active session.
- Restores `SleepDisabled=0` when the Amphetamine session ends or the watchdog is disabled.
- By default, repairs an unowned `SleepDisabled=1` while Amphetamine is inactive, preventing a stale Power Protect state from leaving the Mac awake.
- Restores system sleep at or below the configured low-battery threshold (35% by default).
- Keeps low-battery protection latched until AC power returns or the Amphetamine session ends.
- Uses the two exact `pmset` commands already authorized by Power Protect's sudoers file.

Because the watchdog runs outside Amphetamine's sandbox, it has its own explicit configuration instead of attempting to read Amphetamine's protected preferences.

## Install

Install Amphetamine and Power Protect first. Then, from a local checkout of this repository, run:

```shell
Source/Watchdog/install.zsh
```

The installer adds a user LaunchAgent and prints its initial status. It does not modify the existing Power Protect AppleScript or sudoers file.

## Configure

The configuration file is located at:

```text
~/Library/Application Support/Amphetamine/Power Protect Watchdog/config.plist
```

Set `Enabled` to `false` to stop managing Closed-Display Mode. Change `LowBatteryPercent` to a value from 5 through 95 to adjust the safety threshold. Invalid values fall back to 35%.

`ResetSleepWhenInactive` defaults to `true`. Set it to `false` only if another tool intentionally uses `pmset disablesleep` while Amphetamine has no active session; watchdog-owned state is still cleaned up.

Changes are read on every reconciliation and do not require restarting the LaunchAgent.

## Status

```shell
~/Library/Application\ Support/Amphetamine/Power\ Protect\ Watchdog/power-protect-watchdog.zsh --status
```

## Uninstall

From the same repository checkout, run:

```shell
Source/Watchdog/uninstall.zsh
```

Uninstalling restores normal system sleep when `ResetSleepWhenInactive` is enabled (or when the watchdog owns the current state), then removes only the watchdog files.

## Tests

```shell
Tests/watchdog-tests.zsh
```

The tests use a fake `pmset` implementation and do not change the Mac's real power-management settings.

> [!WARNING]
> Closed-display operation continues to consume power and generate heat. End the Amphetamine session before putting a MacBook in a bag or other enclosed space.
