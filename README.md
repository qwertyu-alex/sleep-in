# Sleep In

Keep your Mac awake for a set time, then put it to sleep.

Start a long build, a download, or a coding agent before bed, and Sleep In
keeps your Mac awake until the countdown ends, then puts it to sleep. It comes
as a native Mac app and a terminal command that share one timer. An optional
lid-closed mode keeps working with the lid shut while on the charger, with no
external display needed.

## Requirements

- macOS 14 Sonoma or later on Apple silicon.
- Apple's Command Line Tools (`xcode-select --install`), which provide Swift
  and Python 3. Python 3.9 or later works; there are no third-party
  dependencies.
- To build the Mac app: a **Developer ID Application** signing certificate from
  the Apple Developer Program. Lid-closed mode's privileged helper only trusts
  code signed by the same Developer ID team. The terminal command works without
  the app, except for `--lid-closed`.

## Install

```sh
git clone https://github.com/qwertyu-alex/sleep-in.git
cd sleep-in
mkdir -p ~/.local/bin
ln -s "$PWD/bin/sleep-in" "$PWD/bin/sleep-in-gui" ~/.local/bin/
./gui/build.sh
```

`build.sh` compiles, signs, and installs `~/Applications/Sleep In.app`. The app
runs the timer through `~/.local/bin/sleep-in`, so that link is needed even if
you only use the app. Add `~/.local/bin` to your `PATH` to use the commands in
Terminal.

The links point into your clone, so keep it where it is. Edits to
`bin/sleep-in` apply to the next timer run; rerun `./gui/build.sh` after
editing Swift.

## Mac app

Open `~/Applications/Sleep In.app` in Finder or search for **Sleep In** in
Spotlight. You can also run `sleep-in-gui` from any terminal.

Set the time on the big number: click − or +, scroll or drag on it, or press
↑ and ↓ (hold Shift to move by an hour). To type a time, click the number or
just start typing, for example `90`, `1:30`, or `1h30`, then press Return.
The presets set 30 minutes to 8 hours in one click. The window shows when your
Mac will sleep, and opens with the duration you used last. Press Return or
click **Start** to keep your Mac awake until the countdown ends.

While the timer runs, **+15 min** and **+1 hour** add time without restarting
it. **Cancel**, closing the window, and quitting the app all cancel the timer;
the app asks before closing or quitting. Minimizing the window lets the timer
continue. The timer also stops if the app crashes or is force-quit.

The app and the terminal command share one timer slot. A timer already running
in Terminal must be cancelled there before a timer can be started in the app.

## Terminal command

The `sleep-in` command prevents idle sleep, then requests system sleep when its
timer expires. It uses the built-in `caffeinate` and `pmset` tools.

```sh
sleep-in 1h                 # Stay awake for one hour, then sleep
sleep-in 1h30m              # One hour and thirty minutes
sleep-in status             # Show remaining time from another terminal
sleep-in extend 15m         # Add time to the running timer
sleep-in 2h --replace       # Restart the countdown at two hours
sleep-in cancel             # Cancel from another terminal
sleep-in 5s --dry-run       # Exercise the timer without putting the Mac to sleep
sleep-in 2h --lid-closed    # Allow the lid to close while on the charger
```

The timer stays in the foreground with a live countdown. Press Ctrl+C or close
the terminal to cancel and release the keep-awake assertion. Only one timer
can run at a time.

State lives in `~/.local/share/sleep-in/`. Errors appear in the terminal; you
can also check `sleep-in status`.

## Lid-closed mode

Without lid-closed mode, keep your laptop lid open: the timer only prevents
idle sleep and does not change persistent power settings.

To keep working with the lid closed and just the charger connected, enable
**Keep awake with lid closed** in the app before starting, or pass
`--lid-closed` in Terminal. Lid-closed mode needs the Sleep In app to be
installed, including when you start it from Terminal. Each start asks for
Touch ID, or your login password when Touch ID is unavailable, such as with the
lid closed. The countdown starts after approval, and the app remembers the
checkbox for next time. Cancel the prompt or click **Cancel** to abandon
startup.

The first time, Sleep In asks macOS to allow its background helper and opens
System Settings. Turn on **Sleep In** under **General → Login Items &
Extensions**, then press **Start** again. This is needed once.

Lid-closed mode controls macOS's system-wide `disablesleep` setting, and only
while the Mac is running on AC power. Unplugging restores normal lid-close
sleep; reconnecting the charger enables the override again while the timer is
still running. The running window shows which mode is active. While the
override is active, manual sleep is blocked too.

Lock your Mac with **Control–Command–Q** before closing the lid: disabling
lid-close sleep can also prevent the usual lock-on-sleep behavior.

In Terminal, `--dry-run` with `--lid-closed` still changes lid-close behavior
during the countdown. At the end it restores normal settings without sending a
sleep command; macOS can then sleep if the lid is still closed.

### How the helper works

Changing `disablesleep` needs root, so the timer itself stays unprivileged and
asks a small helper to do it:

- The helper is a launch daemon inside the app. macOS starts it only when a
  lid-closed session begins, and it exits about 10 seconds after the session
  ends.
- It accepts requests only from Sleep In's own client, signed with the same
  Developer ID, after Touch ID approval. The client, in turn, only talks to a
  daemon with that same signature.
- The timer restores sleep before its final sleep request, on cancellation, or
  when the app quits. The helper also restores sleep if the timer crashes or
  stops responding.
- The helper records ownership in `/var/run/sleep-in-lid.lock`, prevents
  competing lid-closed sessions, and recovers an interrupted override the next
  time you start one.
- If another tool has already disabled system sleep, Sleep In leaves it alone
  and asks you to enable sleep there first.

Turning Sleep In off under Login Items & Extensions disables lid-closed mode.

If the Mac loses power or the root helper itself is force-killed, normal
cleanup cannot run. Start and cancel another lid-closed session to recover, or
restore sleep explicitly with `sudo pmset -a disablesleep 0`.

## Limitations

- Sleep In cannot prevent shutdown or a depleted battery.
- The timer does not restart after a reboot.
- The display may turn off while the Mac keeps working.
- The deadline is a fixed wall-clock time. If you manually sleep before then,
  an overdue timer requests sleep after the Mac wakes again.
- The timer does not check whether your work is done; it requests sleep at the
  deadline even if a job or agent is still busy.
- A successful sleep request does not guarantee the Mac stays asleep if another
  device or scheduled event wakes it.

## Uninstall

1. Quit Sleep In and run `sleep-in cancel`.
2. Turn off **Sleep In** under System Settings → General → Login Items &
   Extensions.
3. Remove `~/Applications/Sleep In.app`, `~/.local/bin/sleep-in`,
   `~/.local/bin/sleep-in-gui`, and `~/.local/share/sleep-in/`.
4. Delete your clone of this repository.

## Development

- `bin/sleep-in`: the Python timer and macOS keep-awake and sleep controls.
- `bin/lid_awake.py`: the timer's side of a lid-closed session.
- `bin/sleep-in-gui`: opens the installed Mac app.
- `gui/SleepIn.swift`: the native SwiftUI window and countdown controls.
- `gui/LidAwakeDaemon.swift`: the root launch daemon that changes lid-close
  sleep for one session at a time.
- `gui/LidAwakeClient.swift`: asks for Touch ID, then asks the daemon to start
  a session for the timer.
- `gui/LidAwakeService.swift`: the connection definition and signature check
  shared by both.
- `gui/LidSleepPolicy.swift`: when the daemon enables and restores sleep.
- `gui/build.sh`: compiles, signs, and installs the app.
- `gui/Resources/`: the moon-and-countdown logo for the app, Dock, and Finder.
- `design/`: the original interface mockup.

### Building and signing

`./gui/build.sh` signs the app with the first **Developer ID Application**
certificate in your keychain; set `SLEEP_IN_SIGNING_IDENTITY` to choose
another. Signing needs a network connection for Apple's timestamp. The build
replaces the installed app only after signing succeeds, and a running timer
keeps going; quit and reopen Sleep In afterward to use the new version.

The logo source is `gui/Resources/SleepIn.png`. After changing it, run
`./gui/build-icon.sh` to regenerate all standard and Retina icon sizes, then
`./gui/build.sh` to install the updated icon.

### Tests

Automated checks do not change system power settings or ask for a password:

```sh
python3 -m unittest discover -s tests -v
xcrun swiftc gui/LidSleepPolicy.swift tests/LidSleepPolicyTests.swift -o /tmp/sleep-in-policy-tests
/tmp/sleep-in-policy-tests
```

To check on hardware, start a timer with lid-closed mode enabled, approve with
Touch ID, lock the Mac, and close the lid with the charger connected. Confirm
ongoing work continues. Opening the lid, unplugging, and reconnecting should
update the window's power status. Cancel with the lid open before the countdown
ends and check `pmset -g`: `SleepDisabled` should be absent or `0`.

Issues and pull requests are welcome. Please run the tests above before
opening a pull request.

## License

[MIT](LICENSE)
