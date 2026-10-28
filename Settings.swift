// Settings window: per-gesture switches and timings. Values live in
// UserDefaults; AppController reloads `config` whenever they change.

import AppKit
import SwiftUI

struct SettingsView: View {
    private static let d = Config()

    @AppStorage("leftClick") private var leftClick = true
    @AppStorage("leftDrag") private var leftDrag = true
    @AppStorage("rightClick") private var rightClick = true
    @AppStorage("rightDrag") private var rightDrag = true
    @AppStorage("middleClick") private var middleClick = true
    @AppStorage("middleDrag") private var middleDrag = true

    @AppStorage("tapTime") private var tapTime = d.tapTime
    @AppStorage("dragTimeout") private var dragTimeout = d.dragTimeout
    @AppStorage("moveThreshold") private var moveThreshold = d.moveThreshold
    @AppStorage("clickGap") private var clickGap = d.clickGap

    var body: some View {
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Tap with")
                        Text("Click")
                        Text("Drag")
                    }
                    .foregroundStyle(.secondary)
                    gestureRow("1 finger", "left", $leftClick, $leftDrag)
                    gestureRow("2 fingers", "right", $rightClick, $rightDrag)
                    gestureRow("3 fingers", "middle", $middleClick, $middleDrag)
                }
            } header: {
                Text("Gestures")
            } footer: {
                Text("Drag: tap, then put one finger back down within the drag window and "
                     + "hold or move it. The button is released when the finger lifts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                timingRow("Tap time", "Longest touch that counts as a tap.",
                          $tapTime, 0.05...0.5, step: 0.01, ms(tapTime))
                timingRow("Drag window", "Time after a tap in which a touch starts a drag or double tap. "
                          + "While that gesture's drag is on, its click is released after this.",
                          $dragTimeout, 0.1...1.0, step: 0.01, ms(dragTimeout))
                timingRow("Movement allowed", "How far fingers may move during a tap, as a share of the pad size.",
                          $moveThreshold, 0.005...0.1, step: 0.005,
                          String(format: "%.1f %%", moveThreshold * 100))
                timingRow("Click gap", "Pause between a release and the next press, and how long a click "
                          + "is held when its drag is off. Linux (libinput) drops a release and "
                          + "press closer than about 25 ms.",
                          $clickGap, 0...0.15, step: 0.005, ms(clickGap))
            }

            HStack {
                Spacer()
                SwiftUI.Button("Restore Defaults", action: restoreDefaults) // `Button` is our mouse button enum
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gestureRow(_ fingers: String, _ button: String,
                            _ click: Binding<Bool>, _ drag: Binding<Bool>) -> some View {
        GridRow {
            Text("\(fingers) (\(button))")
            Toggle("\(button) click", isOn: click).labelsHidden()
            Toggle("\(button) drag", isOn: drag).labelsHidden()
        }
    }

    private func timingRow(_ title: String, _ help: String, _ value: Binding<Double>,
                           _ range: ClosedRange<Double>, step: Double, _ shown: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(shown)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Rounding in the binding instead of `step:`, which draws a tick per step.
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = ($0 / step).rounded() * step }),
                   in: range) { Text(title) }
                .labelsHidden()
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ms(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    private func restoreDefaults() {
        for key in Config.registeredDefaults.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "tapdrag Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A menu bar app is never frontmost by itself.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
