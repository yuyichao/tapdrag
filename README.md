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

The build signs the app with the **tapdrag Code Signing** certificate if it is
in your keychain (see [Signing certificate](#signing-certificate)). Otherwise
it is ad-hoc signed, and after every rebuild you have to remove tapdrag from
the Accessibility list and add it again. CMake prints which one it uses
(`-- Signing: …`). To use a different certificate, configure with
`-DTAPDRAG_SIGN_IDENTITY="…"`; `-` forces ad-hoc signing.

GitHub Actions builds the disk image (arm64 only) on every push. Download it
from the run's **tapdrag-dmg** artifact. It is signed with the same
certificate when the repository has the signing secrets; pull requests from
forks are ad-hoc signed. The image comes from the internet and isn't notarized,
so macOS blocks it on first launch. Allow it under System Settings → Privacy &
Security → **Open Anyway**.

To make a release, push a version tag:
```
git tag v0.2.0
git push origin v0.2.0
```
The Release workflow builds `tapdrag-0.2.0.dmg` with the version taken from
the tag, then creates a GitHub release with the image attached. Tags must be
`v` followed by numbers only, such as `v1`, `v1.2` or `v1.2.3`. A tag like
`v1.0-rc1` is rejected. A release fails if the signing secrets are missing.

### Signing certificate

macOS ties the Accessibility permission to the app's signing identity. An
ad-hoc signature changes with every build, so each upgrade looks like a new app.
Signed with a certificate, the identity is "`local.tapdrag` signed by this
certificate", which stays the same, and the permission survives upgrades. A
self-signed certificate is enough; macOS doesn't need to trust it for this.

Use one certificate for both local and GitHub builds, so either can replace the
other. To create it and store it:

1. In a private folder, create a certificate valid for 20 years:
   ```
   openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
     -keyout tapdrag-signing.key -out tapdrag-signing.crt \
     -subj "/CN=tapdrag Code Signing" \
     -addext "basicConstraints=critical,CA:false" \
     -addext "keyUsage=critical,digitalSignature" \
     -addext "extendedKeyUsage=critical,codeSigning"
   ```
   Use the system `openssl` (`/usr/bin/openssl`). With a Homebrew OpenSSL 3,
   add `-legacy` to the next command, or macOS can't import the file.
2. Package the certificate and key into a password-protected file. It asks for
   a password; you need it in the next two steps:
   ```
   openssl pkcs12 -export -inkey tapdrag-signing.key -in tapdrag-signing.crt \
     -name "tapdrag Code Signing" -out tapdrag-signing.p12
   ```
3. Import it into your login keychain for local builds, allowing `codesign` to
   use it without asking:
   ```
   security import tapdrag-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
   ```
   `security find-identity -p codesigning` should now list
   "tapdrag Code Signing". The `CSSMERR_TP_NOT_TRUSTED` note next to it is
   expected and harmless.
4. Add two repository secrets on GitHub, under Settings → Secrets and
   variables → Actions → **New repository secret**:
   - `SIGNING_CERT_P12`: the file, base64-encoded. This copies it to the
     clipboard:
     ```
     base64 -i tapdrag-signing.p12 | pbcopy
     ```
   - `SIGNING_CERT_PASSWORD`: the password from step 2.
5. Delete the unprotected key and the certificate:
   ```
   rm tapdrag-signing.key tapdrag-signing.crt
   ```
   Keep `tapdrag-signing.p12` somewhere safe, such as a password manager, if
   you want to sign on another Mac later; otherwise delete it too. Anyone with
   the key can sign programs that macOS treats as tapdrag.
6. Reconfigure an existing build folder so CMake picks up the certificate:
   ```
   cmake -B build -DTAPDRAG_SIGN_IDENTITY=
   ```
   Then build, install, and grant Accessibility one last time.

If you ever replace the certificate, the identity changes once and you grant
Accessibility again.

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
- **Settings…** (⌘,): turn each gesture on or off and adjust the timings. See
  [Settings](#settings).
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

## Settings

Open **Settings…** from the menu bar icon. Changes apply immediately.

**Gestures**: a Click and a Drag switch for each finger count (1 = left,
2 = right, 3 = middle). All are on by default.

- With only Click on, the click is sent as soon as the fingers lift, without
  waiting for the drag window.
- With only Drag on, a tap alone does nothing. The button is pressed only when
  a finger comes back and holds or moves.

**Timing**:

| Setting | Key | Default | Meaning |
|---|---|---|---|
| Tap time | `tapTime` | 0.20 s | longest touch that counts as a tap |
| Drag window | `dragTimeout` | 0.30 s | time after a tap in which a touch starts a drag or double tap |
| Movement allowed | `moveThreshold` | 0.03 | how far fingers may move during a tap, as a fraction of pad size |
| Click gap | `clickGap` | 0.05 s | minimum time between a release and the next press, and how long a click is held when that gesture's drag is off. libinput in the guest drops a release and press closer than ~25 ms as switch bounce, which turns a double click into one click |

Settings are stored in the `local.tapdrag` preferences, so
`defaults write local.tapdrag tapTime -float 0.25` also works. Restart tapdrag
after changing them that way. The gesture switches use the keys `leftClick`,
`leftDrag`, `rightClick`, `rightDrag`, `middleClick` and `middleDrag`.

The timings are also command-line flags (`--tap-time`, `--drag-timeout`,
`--move-threshold`, `--click-gap`, plus `--debug` to log to stderr) for running
the binary from Terminal. They override the saved settings for that run. Quit
the app first, or both copies will click.
