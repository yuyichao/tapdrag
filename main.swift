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
    var debug = false
}

var config = Config()

func log(_ msg: @autoclosure () -> String) {
    guard config.debug else { return }
    let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    FileHandle.standardError.write("[\(t)] \(msg())\n".data(using: .utf8)!)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("tapdrag: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Buttons and event posting

enum Button: Int64 {
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
        heldClickState = clickState
        log("POST \(button) down (clickState \(clickState))")
    }

    func up() {
        guard let button = held else { return }
        post(button.upType, button, at: cursorLocation(), clickState: heldClickState)
        held = nil
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
    enum State: CustomStringConvertible {
        case idle
        case tapped(Button)       // button is down, waiting for drag/double tap or timeout
        case dragOrDouble(Button) // button is down, a new touch arrived after the tap
        case dragging(Button)     // button is down until all fingers lift

        var description: String {
            switch self {
            case .idle: return "idle"
            case .tapped(let b): return "tapped(\(b))"
            case .dragOrDouble(let b): return "dragOrDouble(\(b))"
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

        if case .dragOrDouble(let b) = state {
            if seqMaxFingers > 1 {
                // More fingers: not a drag. Release and judge this sequence on its own.
                poster.up()
                state = .idle
            } else if seqMoved || time - seqStart > config.tapTime {
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
        if case .tapped(let b) = state {
            timerGeneration += 1
            state = .dragOrDouble(b)
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
        poster.down(button)
        state = .tapped(button)
        timerGeneration += 1
        let gen = timerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + config.dragTimeout) { [self] in
            guard gen == timerGeneration, case .tapped = state else { return }
            poster.up()
            state = .idle
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
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func installEventTap() {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else {
        fail("cannot create event tap. Grant Accessibility permission to this binary in "
             + "System Settings > Privacy & Security > Accessibility, then restart it.")
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
           tapdrag --test-click left|right|middle [DELAY_SEC]

      --tap-time        max duration of a tap (default \(config.tapTime))
      --drag-timeout    time after a tap to start a drag / double tap (default \(config.dragTimeout))
      --move-threshold  max finger travel for a tap, fraction of pad size (default \(config.moveThreshold))
      --debug           log touches, state transitions and posted events to stderr
      --test-click      post one click at the cursor after DELAY_SEC (default 3) and exit
    """)
    exit(2)
}

/// Prompts once, then waits until Accessibility is granted (so launchd doesn't
/// restart us into a prompt loop).
func requirePostAccess() {
    guard !CGPreflightPostEventAccess() else { return }
    _ = CGRequestPostEventAccess()
    FileHandle.standardError.write(("tapdrag: waiting for Accessibility permission for \(CommandLine.arguments[0]) "
        + "(System Settings > Privacy & Security > Accessibility)\n").data(using: .utf8)!)
    while !CGPreflightPostEventAccess() {
        Thread.sleep(forTimeInterval: 2)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    func value() -> Double {
        guard let s = args.first, let v = Double(s) else { usage() }
        args.removeFirst()
        return v
    }
    switch arg {
    case "--debug": config.debug = true
    case "--tap-time": config.tapTime = value()
    case "--drag-timeout": config.dragTimeout = value()
    case "--move-threshold": config.moveThreshold = value()
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

requirePostAccess()
installEventTap()

let deviceManager = DeviceManager()
deviceManager.start()
if deviceManager.count == 0 { fail("no multitouch devices found") }

// Devices go stale across sleep. (After (re)connecting a Magic Trackpad,
// restart the agent: launchctl kickstart -k gui/$UID/local.tapdrag)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    log("wake: restarting devices")
    deviceManager.restart()
}

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

FileHandle.standardError.write("tapdrag running (\(deviceManager.count) device(s))\n".data(using: .utf8)!)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
