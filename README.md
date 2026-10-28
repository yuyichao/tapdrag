# tapdrag

libinput-style tapping for the macOS trackpad. It runs only on the host, and
because it posts ordinary mouse events, the Parallels Linux guest gets them too.

| Gesture | Result |
|---|---|
| 1-finger tap | left click |
| 2-finger tap | right click |
| 3-finger tap | middle click |
| N-finger tap, then within 0.3 s one finger touches and stays/moves | button N held (drag) |
| … finger lifts | button released immediately (no drag lock) |
| quick tap after a tap | double click |

Physically pressing the trackpad still works as before.

## How it works

- Raw touches come from the private `MultitouchSupport.framework`, the same one
  MiddleClick and BetterTouchTool use.
- On an N-finger tap it posts button N **down** when the fingers lift and holds
  off the **up** for 0.3 s. If a finger comes back in that window and stays, the
  button stays down until it lifts. That is the drag. Without this, a tap
  followed by a drag would look like a double-click drag, both to the host and
  to the guest, which detects double clicks on its own.
- While a synthetic button is held, a session event tap rewrites the
  trackpad's `mouseMoved` events as `left/right/otherMouseDragged`.

## Building

Needs CMake ≥ 3.29, Ninja (`brew install cmake ninja`) and the Xcode command
line tools.

```
cmake -G Ninja -B build
cmake --build build                  # build/tapdrag.app
cmake --build build --target dmg     # build/tapdrag-0.1.0.dmg
```

The app is ad-hoc signed by default. macOS ties the Accessibility permission to
the signature, so after every rebuild you have to remove tapdrag from the
Accessibility list and add it again. If you have a signing certificate, such as
the free "Apple Development" one that Xcode makes for an Apple ID, configure
with `-DTAPDRAG_SIGN_IDENTITY="Apple Development: …"` and the permission
survives rebuilds.

## Installing

Open `tapdrag-0.1.0.dmg` and drag **tapdrag** onto **Applications**. Or run
`cmake --install build`, which puts it in `/Applications`; change that with
`-DCMAKE_INSTALL_PREFIX=…`. Quit a running tapdrag before replacing it.

Start it from Applications. It has no Dock icon, only a hand icon in the menu
bar. On first launch macOS asks for Accessibility. Allow **tapdrag** under
System Settings → Privacy & Security → Accessibility. The icon stays greyed out
until you do, then tapdrag starts working.

The menu has these items:

- **Enabled**: pause or resume tap handling.
- **Start at Login**: launch tapdrag when you log in. It shows under System
  Settings → General → Login Items.
- **Restart Touch Devices**: use after connecting a Magic Trackpad.
- **Debug Logging** / **Show Log**: write every touch sequence, state change
  and posted click to `~/Library/Logs/tapdrag.log`.

Uninstall: quit it, turn off Start at Login, then delete the app, or run
`cmake --build build --target uninstall`.

## Setup

0. **Check the touch reading first, before changing any settings.** Install
   and start the app, then turn on **Debug Logging** and choose **Show Log**.
   Tap once with one finger. Native tap-to-click is still on, so you get two
   clicks; ignore that for now. The log should show `fingers 0 -> 1`, then
   `sequence end: 1 finger(s), ~50–150 ms … TAP`. Try a two-finger tap and a
   three-finger tap too. If the finger counts or the times look wrong, uncheck
   **Enabled** and keep the log.
1. **System Settings → Trackpad → Point & Click:** turn **Tap to click** off.
   tapdrag handles taps now, and leaving this on gives double clicks.
2. **System Settings → Accessibility → Pointer Control → Trackpad Options:**
   turn **Use trackpad for dragging** off.
3. Optional: under Trackpad → Scroll & Zoom, turn off **Smart zoom**. It also
   reacts to a two-finger double tap.
4. If BetterTouchTool runs, remove any 1/2/3-finger *tap* triggers from it.

## Checking the VM path

Move the pointer over the VM, and inside the guest run `xev` or
`sudo libinput debug-events`. Then run this in Terminal:
```
/Applications/tapdrag.app/Contents/MacOS/tapdrag --test-click middle
```
This posts one middle click after 3 s. If the guest shows button 2, synthetic
events reach it.

Programs started from Terminal use *Terminal's* Accessibility permission, not
tapdrag's. Allow Terminal (or your terminal app) once for this test, and remove
it afterwards if you like.

## Tuning

| Setting | Default | Meaning |
|---|---|---|
| `tapTime` | 0.20 | longest touch, in seconds, that counts as a tap |
| `dragTimeout` | 0.30 | seconds after a tap in which a touch starts a drag or double tap |
| `moveThreshold` | 0.03 | how far fingers may move during a tap, as a fraction of pad size |
| `clickGap` | 0.05 | minimum seconds between a release and the next press. libinput in the guest drops a release and press closer than ~25 ms as switch bounce, which turns a double click into one click |

Set them with `defaults write local.tapdrag tapTime -float 0.25`, then quit and
reopen tapdrag. The same settings are also command-line flags
(`--tap-time`, `--drag-timeout`, `--move-threshold`, `--click-gap`, `--debug` to log to
stderr) for running the binary from Terminal. Quit the app first, or both copies
will click.
