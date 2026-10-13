import AppKit

final class GestureSettingsController: NSObject {
    private let gestures: HorizontalGestureRouter
    private(set) var window: NSWindow?
    private var enabledButton: NSButton?
    private var reversedButton: NSButton?
    private var slider: NSSlider?
    private var valueLabel: NSTextField?
    var onChange: (() -> Void)?

    init(gestures: HorizontalGestureRouter) { self.gestures = gestures; super.init() }

    func show() {
        if let window { sync(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 315),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SpaceHop — жесты трекпада"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        guard let root = window.contentView else { return }
        func label(_ text: String, frame: NSRect, font: NSFont = .systemFont(ofSize: 13), secondary: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font; label.textColor = secondary ? .secondaryLabelColor : .labelColor
            label.frame = frame; root.addSubview(label); return label
        }
        let enabled = NSButton(checkboxWithTitle: "Мгновенные свайпы между Spaces", target: self, action: #selector(changeEnabled(_:)))
        enabled.frame = NSRect(x: 24, y: 264, width: 420, height: 27)
        root.addSubview(enabled); enabledButton = enabled
        _ = label("Чувствительность", frame: NSRect(x: 24, y: 220, width: 340, height: 22), font: .systemFont(ofSize: 14, weight: .medium))
        valueLabel = label("", frame: NSRect(x: 392, y: 220, width: 54, height: 22))
        let slider = NSSlider(value: gestures.sensitivity, minValue: 1, maxValue: 100, target: self, action: #selector(changeSensitivity(_:)))
        slider.isContinuous = true; slider.frame = NSRect(x: 24, y: 185, width: 420, height: 28)
        slider.setAccessibilityLabel("Чувствительность переключения рабочих столов")
        root.addSubview(slider); self.slider = slider
        _ = label("Ниже", frame: NSRect(x: 24, y: 166, width: 120, height: 18), secondary: true)
        _ = label("Выше", frame: NSRect(x: 401, y: 166, width: 45, height: 18), secondary: true)
        _ = label("Выше чувствительность — короче движение до переключения. Один свайп переключает на один рабочий стол.",
                  frame: NSRect(x: 24, y: 112, width: 420, height: 44), secondary: true)
        let reversed = NSButton(checkboxWithTitle: "Поменять направления местами", target: self, action: #selector(changeReversed(_:)))
        reversed.frame = NSRect(x: 24, y: 77, width: 420, height: 25)
        root.addSubview(reversed); reversedButton = reversed
        _ = label("Используется системный жест тремя или четырьмя пальцами. Изменения применяются сразу.",
                  frame: NSRect(x: 24, y: 18, width: 265, height: 47), font: .systemFont(ofSize: 12), secondary: true)
        let reset = NSButton(title: "По умолчанию", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded; reset.frame = NSRect(x: 303, y: 23, width: 143, height: 32)
        root.addSubview(reset)
        self.window = window
        sync(); window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func sync() {
        enabledButton?.state = gestures.enabled ? .on : .off
        reversedButton?.state = gestures.reversed ? .on : .off
        slider?.doubleValue = gestures.sensitivity
        slider?.isEnabled = gestures.enabled
        reversedButton?.isEnabled = gestures.enabled
        valueLabel?.stringValue = "\(Int(gestures.sensitivity.rounded()))%"
    }
    @objc private func changeEnabled(_ sender: NSButton) { gestures.enabled = sender.state == .on; sync(); onChange?() }
    @objc private func changeSensitivity(_ sender: NSSlider) { gestures.sensitivity = sender.doubleValue.rounded(); sync(); onChange?() }
    @objc private func changeReversed(_ sender: NSButton) { gestures.reversed = sender.state == .on; sync(); onChange?() }
    @objc private func resetDefaults() { gestures.enabled = true; gestures.sensitivity = 75; gestures.reversed = false; sync(); onChange?() }
}
