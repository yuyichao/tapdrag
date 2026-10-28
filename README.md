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
cmake --build build
```

The binary is `build/tapdrag`. It is ad-hoc signed with the identifier
`local.tapdrag`.

## Setup

0. **Check the touch reading first, before changing any settings.** Build it
   and run it in a terminal:
   ```
   ./build/tapdrag --debug
   ```
   It asks for Accessibility and waits until you allow the binary under
   Privacy & Security → Accessibility. Then tap once with one finger. Native
   tap-to-click is still on, so you get two clicks; ignore that for now. The log
   should show `fingers 0 -> 1`, then `sequence end: 1 finger(s), ~50–150 ms …
   TAP`. Try a two-finger tap and a three-finger tap too. If the finger counts
   or the times look wrong, stop here and keep the log. Ctrl-C to quit.
1. **System Settings → Trackpad → Point & Click:** turn **Tap to click** off.
   tapdrag handles taps now, and leaving this on gives double clicks.
2. **System Settings → Accessibility → Pointer Control → Trackpad Options:**
   turn **Use trackpad for dragging** off.
3. Optional: under Trackpad → Scroll & Zoom, turn off **Smart zoom**. It also
   reacts to a two-finger double tap.
4. If BetterTouchTool runs, remove any 1/2/3-finger *tap* triggers from it.
5. Install as a login agent:
   ```
   cmake --install build
   ```
   This installs `~/.local/bin/tapdrag` and
   `~/Library/LaunchAgents/local.tapdrag.plist`, then (re)starts the agent.
   The installed binary needs its own Accessibility entry. The agent waits
   until you add it, then starts working. After a rebuild and reinstall, remove
   the entry and add it again. Log: `~/Library/Logs/tapdrag.log`.

   Options:
   - `-DCMAKE_INSTALL_PREFIX=…` installs the binary elsewhere (default `~/.local`).
   - `-DTAPDRAG_INSTALL_AGENT=OFF` installs only the binary.

   Uninstall with `cmake --build build --target uninstall`.

After connecting or reconnecting a Magic Trackpad, restart the agent:
`launchctl kickstart -k gui/$UID/local.tapdrag`.

## Checking the VM path

Move the pointer over the VM, and inside the guest run `xev` or
`sudo libinput debug-events`. Then run:
```
./build/tapdrag --test-click middle
```
This posts one middle click after 3 s. If the guest shows button 2, synthetic
events reach it.

## Tuning

`--tap-time 0.20` (longest touch that counts as a tap), `--drag-timeout 0.30`,
`--move-threshold 0.03` (fraction of pad size). `--debug` prints finger counts,
state changes and every posted event to stderr. If a gesture misbehaves, that
output shows why.
