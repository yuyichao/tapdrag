// tapdrag: libinput-style tap / tap-and-drag for the macOS trackpad.
//
//   1-finger tap -> left click     1-finger tap, then touch & hold -> left drag
//   2-finger tap -> right click    2-finger tap, then 1 finger hold -> right drag
//   3-finger tap -> middle click   3-finger tap, then 1 finger hold -> middle drag
//
// Drags end as soon as the last finger lifts (no drag lock).
//
// Raw touches come from the private MultitouchSupport framework; clicks are
// posted as ordinary CGEvents, so they reach every app, Parallels VMs included.
// While a synthetic button is held, a session event tap rewrites the trackpad's
// mouseMoved events into the matching *MouseDragged events.
//
// macOS's own "Tap to click" and "Use trackpad for dragging" must be OFF.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Configuration

struct Config {
    var tapTime = 0.20       // max seconds a touch sequence may last to count as a tap
    var dragTimeout = 0.30   // seconds after a tap during which a new touch starts a drag/double tap
    var moveThreshold = 0.03 // max normalized finger travel (0..1 of pad size) for a tap
    var clickGap = 0.05      // min seconds between a release and the next press (see Poster.down)
    var clickEnabled = Set(Button.allCases) // N-finger tap clicks
    var dragEnabled = Set(Button.allCases)  // N-finger tap, then hold, drags
    var ignoreTapsWhileTyping = true    // palm rejection for taps
    var ignoreScrollWhileTyping = false // drop trackpad scrolling too
    var typingTimeout = 0.5  // seconds after the last key press that count as typing
    var debug = false        // log to stderr

    // UserDefaults keys. Settings are edited in the Settings window, or with e.g.
    // `defaults write local.tapdrag tapTime -float 0.25`.
    static func clickKey(_ b: Button) -> String { "\(b)Click" } // leftClick, rightClick, middleClick
    static func dragKey(_ b: Button) -> String { "\(b)Drag" }

    static var registeredDefaults: [String: Any] {
        let c = Config()
        var d: [String: Any] = ["tapTime": c.tapTime, "dragTimeout": c.dragTimeout,
                                "moveThreshold": c.moveThreshold, "clickGap": c.clickGap,
                                "ignoreTapsWhileTyping": c.ignoreTapsWhileTyping,
                                "ignoreScrollWhileTyping": c.ignoreScrollWhileTyping,
                                "typingTimeout": c.typingTimeout]
        for b in Button.allCases {
            d[clickKey(b)] = true
            d[dragKey(b)] = true
        }
        return d
    }

    /// Needs `registeredDefaults` registered first.
    mutating func load(from defaults: UserDefaults) {
        tapTime = defaults.double(forKey: "tapTime")
        dragTimeout = defaults.double(forKey: "dragTimeout")
        moveThreshold = defaults.double(forKey: "moveThreshold")
        clickGap = defaults.double(forKey: "clickGap")
        clickEnabled = Set(Button.allCases.filter { defaults.bool(forKey: Config.clickKey($0)) })
        dragEnabled = Set(Button.allCases.filter { defaults.bool(forKey: Config.dragKey($0)) })
        ignoreTapsWhileTyping = defaults.bool(forKey: "ignoreTapsWhileTyping")
        ignoreScrollWhileTyping = defaults.bool(forKey: "ignoreScrollWhileTyping")
        typingTimeout = defaults.double(forKey: "typingTimeout")
    }
}

var config = Config()

let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/tapdrag.log")
var logFile: FileHandle? // set while "Debug Logging" is on in the menu

func log(_ msg: @autoclosure () -> String) {
    guard config.debug || logFile != nil else { return }
    let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    let line = "[\(t)] \(msg())\n".data(using: .utf8)!
    if config.debug { FileHandle.standardError.write(line) }
    logFile?.write(line)
}

/// The privacy permission tapdrag needs. macOS 27 renamed Accessibility to
/// Device Control and Data Access.
let permissionName = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    ? "Device Control and Data Access" : "Accessibility"

func fail(_ msg: String) -> Never {
    let line = "tapdrag: \(msg)\n".data(using: .utf8)!
    FileHandle.standardError.write(line)
    logFile?.write(line)
    exit(1)
}

// MARK: - Buttons and event posting

enum Button: Int64, CaseIterable {
    case left = 0, right = 1, middle = 2

    init?(fingers: Int) {
        switch fingers {
        case 1: self = .left
        case 2: self = .right
        case 3: self = .middle
        default: return nil
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var draggedType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    var cgButton: CGMouseButton { CGMouseButton(rawValue: UInt32(rawValue))! }
}

// Marks events we post so our own event tap leaves them alone.
let syntheticMarker: Int64 = 0x7461_7064 // "tapd"

func cursorLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

final class Poster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var held: Button?
    private var heldClickState: Int64 = 1
    private var lastDown: (time: TimeInterval, button: Button, location: CGPoint, clickState: Int64)?
    private var lastUp: TimeInterval = 0
    private var pressCount = 0

    private func post(_ type: CGEventType, _ button: Button, at loc: CGPoint, clickState: Int64) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: loc, mouseButton: button.cgButton) else { return }
        ev.setIntegerValueField(.mouseEventButtonNumber, value: button.rawValue)
        ev.setIntegerValueField(.mouseEventClickState, value: clickState)
        ev.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        ev.post(tap: .cghidEventTap)
    }

    func down(_ button: Button) {
        if held != nil { up() }
        // libinput in a Linux guest treats a release followed by a press within
        // ~25 ms as switch bounce and drops both, so a double tap would arrive
        // as one click. Keep the press clear of the previous release.
        let sinceUp = ProcessInfo.processInfo.systemUptime - lastUp
        if sinceUp < config.clickGap {
            usleep(useconds_t((config.clickGap - sinceUp) * 1_000_000))
        }
        let loc = cursorLocation()
        let now = ProcessInfo.processInfo.systemUptime
        var clickState: Int64 = 1
        if let last = lastDown, last.button == button,
           now - last.time <= NSEvent.doubleClickInterval,
           hypot(loc.x - last.location.x, loc.y - last.location.y) <= 5 {
            clickState = last.clickState + 1
        }
        lastDown = (now, button, loc, clickState)
        post(button.downType, button, at: loc, clickState: clickState)
        held = button
        pressCount += 1
        heldClickState = clickState
        log("POST \(button) down (clickState \(clickState))")
    }

    /// Press and release after holding for clickGap, so the guest sees two
    /// separate transitions instead of a press and release that got merged.
    func click(_ button: Button) {
        down(button)
        let press = pressCount
        DispatchQueue.main.asyncAfter(deadline: .now() + max(config.clickGap, 0.02)) { [self] in
            if press == pressCount { up() }
        }
    }

    func up() {
        guard let button = held else { return }
        post(button.upType, button, at: cursorLocation(), clickState: heldClickState)
        held = nil
        lastUp = ProcessInfo.processInfo.systemUptime
        log("POST \(button) up")
    }
}

// MARK: - Gesture state machine (main thread only)

struct Touch {
    var id: Int32
    var x: Float
    var y: Float
}

final class Engine {
    // `pressed` says whether the button is already down. It is false when that
    // button's click is turned off but its drag is on: the press then waits
    // until the touch turns out to be a drag.
    enum State: CustomStringConvertible {
        case idle
        case tapped(Button, pressed: Bool)       // waiting for drag/double tap or timeout
        case dragOrDouble(Button, pressed: Bool) // a new touch arrived after the tap
        case dragging(Button)                    // button is down until all fingers lift

        var description: String {
            switch self {
            case .idle: return "idle"
            case .tapped(let b, let p): return "tapped(\(b)\(p ? "" : ", not pressed"))"
            case .dragOrDouble(let b, let p): return "dragOrDouble(\(b)\(p ? "" : ", not pressed"))"
            case .dragging(let b): return "dragging(\(b))"
            }
        }
    }

    let poster = Poster()
    private(set) var state = State.idle {
        didSet { log("state \(oldValue) -> \(state)") }
    }
    private var timerGeneration = 0

    // Current touch sequence (from first finger down to last finger up, across all devices).
    private var contacts: [Int: [Touch]] = [:]
    private var seqActive = false
    private var seqStart = 0.0
    private var seqMaxFingers = 0
    private var seqStartPos: [String: (Float, Float)] = [:]
    private var seqMoved = false
    private var seqInvalid = false
    private var lastKeyTime = -Double.infinity // systemUptime of the last typing key press
    private var lastCount = 0

    func frame(device: Int, touches: [Touch], time: Double) {
        contacts[device] = touches
        let all = contacts.flatMap { dev, ts in ts.map { ("\(dev):\($0.id)", $0) } }
        let n = all.count
        if n != lastCount {
            log("fingers \(lastCount) -> \(n)")
            lastCount = n
        }

        if !seqActive {
            guard n > 0 else { return }
            beginSequence(time)
        }

        seqMaxFingers = max(seqMaxFingers, n)
        for (key, t) in all {
            guard let start = seqStartPos[key] else {
                seqStartPos[key] = (t.x, t.y)
                continue
            }
            if !seqMoved, hypot(t.x - start.0, t.y - start.1) > Float(config.moveThreshold) {
                seqMoved = true
                log("sequence moved")
            }
        }

        if case .dragOrDouble(let b, let pressed) = state {
            if seqMaxFingers > 1 {
                // More fingers: not a drag. Release and judge this sequence on its own.
                poster.up()
                state = .idle
            } else if seqMoved || time - seqStart > config.tapTime {
                if !pressed { poster.down(b) }
                state = .dragging(b)
            }
        }

        if n == 0 { endSequence(time) }
    }

    private func beginSequence(_ time: Double) {
        seqActive = true
        seqStart = time
        seqMaxFingers = 0
        seqStartPos = [:]
        seqMoved = false
        seqInvalid = false
        if config.ignoreTapsWhileTyping && isTyping {
            seqInvalid = true
            log("touch while typing: not a tap")
        }
        if case .tapped(let b, let pressed) = state {
            timerGeneration += 1
            state = .dragOrDouble(b, pressed: pressed)
        }
    }

    private func endSequence(_ time: Double) {
        seqActive = false
        let duration = time - seqStart
        let isTap = !seqInvalid && !seqMoved && duration <= config.tapTime
            && Button(fingers: seqMaxFingers) != nil
        log(String(format: "sequence end: %d finger(s), %.0f ms, moved=%@, invalid=%@ -> %@",
                   seqMaxFingers, duration * 1000, "\(seqMoved)", "\(seqInvalid)", isTap ? "TAP" : "no tap"))

        switch state {
        case .dragging:
            poster.up()
            state = .idle
        case .dragOrDouble:
            // Quick second tap: finish the first click, then this one is a new tap (double click).
            poster.up()
            state = .idle
            if isTap { tap(fingers: seqMaxFingers) }
        case .idle:
            if isTap { tap(fingers: seqMaxFingers) }
        case .tapped:
            break // unreachable: a new sequence always leaves .tapped
        }
    }

    private func tap(fingers: Int) {
        guard let button = Button(fingers: fingers) else { return }
        let click = config.clickEnabled.contains(button)
        guard config.dragEnabled.contains(button) else {
            // No drag to wait for: click right away.
            if click { poster.click(button) }
            return
        }
        if click { poster.down(button) }
        state = .tapped(button, pressed: click)
        timerGeneration += 1
        let gen = timerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + config.dragTimeout) { [self] in
            guard gen == timerGeneration, case .tapped = state else { return }
            poster.up()
            state = .idle
        }
    }

    var isTyping: Bool {
        ProcessInfo.processInfo.systemUptime - lastKeyTime < config.typingTimeout
    }

    /// A key press that counts as typing (palm rejection, like libinput's
    /// disable-while-typing). Touches already on the pad stop being tap
    /// candidates; drags in progress are left alone.
    func typingKey() {
        if !isTyping { log("typing") }
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        if config.ignoreTapsWhileTyping && seqActive && !seqInvalid {
            seqInvalid = true
            log("key during touch: not a tap")
        }
    }

    /// A real (physical) button press: never turn the current touches into a tap,
    /// and drop any synthetic button we are holding.
    func physicalButton() {
        if seqActive { seqInvalid = true }
        if case .idle = state { return }
        timerGeneration += 1
        poster.up()
        state = .idle
    }

    func reset() {
        contacts = [:]
        lastCount = 0
        if seqActive { seqActive = false }
        timerGeneration += 1
        poster.up()
        state = .idle
    }
}

let engine = Engine()

// MARK: - Event tap: turn trackpad motion into drags while a button is held

var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
        return Unmanaged.passUnretained(event)
    }
    switch type {
    case .mouseMoved:
        if let b = engine.poster.held {
            event.type = b.draggedType
            event.setIntegerValueField(.mouseEventButtonNumber, value: b.rawValue)
        }
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        log("physical \(type.rawValue)")
        engine.physicalButton()
    case .keyDown:
        // Shortcuts (⌘/⌃ + key) aren't typing; they are often used together with
        // the trackpad. Neither are Esc or modifier keys pressed on their own.
        // Only the time is recorded, never which key.
        if event.flags.isDisjoint(with: [.maskCommand, .maskControl])
            && !nonTypingKeys.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            engine.typingKey()
        }
    case .scrollWheel:
        // Continuous scrolling comes from the trackpad (or a Magic Mouse), not a wheel.
        if config.ignoreScrollWhileTyping && engine.isTyping
            && event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            return nil
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// Virtual key codes (HIToolbox Events.h) that don't count as typing: Esc, and the
// modifiers. Modifiers normally arrive as flagsChanged, which the tap doesn't
// watch, but key remappers can post them as keyDown.
let nonTypingKeys: Set<Int64> = [
    53,                     // Escape
    54, 55,                 // right/left Command
    56, 60,                 // left/right Shift
    57,                     // Caps Lock
    58, 61,                 // left/right Option
    59, 62,                 // left/right Control
    63, 179,                // fn / Globe
]

func installEventTap() {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                .keyDown, .scrollWheel]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else {
        fail("cannot create event tap. Allow tapdrag in System Settings > Privacy & Security > "
             + "\(permissionName), then restart it.")
    }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

// MARK: - MultitouchSupport

typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<MTTouch>?,
                                              Int32, Double, Int32) -> Int32
typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>
typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

struct MTAPI {
    let createList: MTDeviceCreateListFn
    let register: MTRegisterFn
    let unregister: MTRegisterFn
    let start: MTDeviceStartFn
    let stop: MTDeviceStopFn

    init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_NOW) else { fail("cannot load MultitouchSupport") }
        func sym<T>(_ name: String, _: T.Type) -> T {
            guard let p = dlsym(h, name) else { fail("missing symbol \(name)") }
            return unsafeBitCast(p, to: T.self)
        }
        createList = sym("MTDeviceCreateList", MTDeviceCreateListFn.self)
        register = sym("MTRegisterContactFrameCallback", MTRegisterFn.self)
        unregister = sym("MTUnregisterContactFrameCallback", MTRegisterFn.self)
        start = sym("MTDeviceStart", MTDeviceStartFn.self)
        stop = sym("MTDeviceStop", MTDeviceStopFn.self)
    }
}

let mtCallback: MTContactCallback = { device, touches, count, timestamp, _ in
    var list: [Touch] = []
    if let touches {
        for i in 0..<Int(count) {
            let t = touches[i]
            // MakeTouch / Touching: finger is on the surface. Hover/break/linger are not contacts.
            if t.state == 3 || t.state == 4 {
                list.append(Touch(id: t.identifier, x: t.normalized.pos.x, y: t.normalized.pos.y))
            }
        }
    }
    let key = Int(bitPattern: device)
    DispatchQueue.main.async { engine.frame(device: key, touches: list, time: timestamp) }
    return 0
}

final class DeviceManager {
    private let api = MTAPI()
    private var devices: CFArray?

    private var deviceRefs: [UnsafeMutableRawPointer] {
        guard let devices else { return [] }
        return (0..<CFArrayGetCount(devices)).compactMap {
            UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(devices, $0))
        }
    }

    func start() {
        devices = api.createList().takeRetainedValue()
        for d in deviceRefs {
            api.register(d, mtCallback)
            api.start(d, 0)
        }
        log("listening to \(deviceRefs.count) multitouch device(s)")
    }

    var isRunning: Bool { devices != nil }

    func stop() {
        for d in deviceRefs {
            api.unregister(d, mtCallback)
            api.stop(d)
        }
        devices = nil
    }

    func restart() {
        stop()
        engine.reset()
        start()
    }

    var count: Int { deviceRefs.count }
}

// MARK: - Main

func usage() -> Never {
    print("""
    usage: tapdrag [--debug] [--tap-time SEC] [--drag-timeout SEC] [--move-threshold FRAC]
                   [--click-gap SEC]
           tapdrag --test-click left|right|middle [DELAY_SEC]

      --tap-time        max duration of a tap (default \(config.tapTime))
      --drag-timeout    time after a tap to start a drag / double tap (default \(config.dragTimeout))
      --move-threshold  max finger travel for a tap, fraction of pad size (default \(config.moveThreshold))
      --click-gap       min time between a release and the next press (default \(config.clickGap))
      --debug           log touches, state transitions and posted events to stderr
      --test-click      post one click at the cursor after DELAY_SEC (default 3) and exit
    """)
    exit(2)
}

/// For --test-click: prompts once, then waits until the permission is granted.
func requirePostAccess() {
    guard !CGPreflightPostEventAccess() else { return }
    _ = CGRequestPostEventAccess()
    FileHandle.standardError.write(("tapdrag: waiting for the \(permissionName) permission "
        + "(System Settings > Privacy & Security > \(permissionName))\n").data(using: .utf8)!)
    while !CGPreflightPostEventAccess() {
        Thread.sleep(forTimeInterval: 2)
    }
}

UserDefaults.standard.register(defaults: Config.registeredDefaults)
// Command-line timings go into the argument domain, so they win over saved
// settings for this run, also when config is reloaded after a settings change.
var cliOverrides: [String: Any] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    func value() -> Double {
        guard let s = args.first, let v = Double(s) else { usage() }
        args.removeFirst()
        return v
    }
    switch arg {
    case _ where arg.hasPrefix("-psn_"): break // added by older Finder/LaunchServices
    case "--debug": config.debug = true
    case "--tap-time": cliOverrides["tapTime"] = value()
    case "--drag-timeout": cliOverrides["dragTimeout"] = value()
    case "--move-threshold": cliOverrides["moveThreshold"] = value()
    case "--click-gap": cliOverrides["clickGap"] = value()
    case "--test-click":
        let names: [String: Button] = ["left": .left, "right": .right, "middle": .middle]
        guard let name = args.first, let button = names[name] else { usage() }
        args.removeFirst()
        let delay = args.first.flatMap(Double.init) ?? 3
        requirePostAccess()
        print("posting a \(name) click at the cursor in \(delay)s...")
        Thread.sleep(forTimeInterval: delay)
        config.debug = true
        let poster = Poster()
        poster.down(button)
        Thread.sleep(forTimeInterval: 0.05)
        poster.up()
        exit(0)
    default: usage()
    }
}

if !cliOverrides.isEmpty {
    let argDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    UserDefaults.standard.setVolatileDomain(argDomain.merging(cliOverrides) { $1 },
                                           forName: UserDefaults.argumentDomain)
}
config.load(from: .standard)

// Never leave a button stuck down on exit.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        engine.reset()
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
