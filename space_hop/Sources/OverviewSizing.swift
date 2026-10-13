import AppKit

// Sizes use logical screen points, so macOS display scaling is already accounted for.
final class OverviewSizing {
    private let defaults: UserDefaults
    private let key = "overviewCardWidthsByDisplay"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func displayKey(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func automaticWidth(in area: CGSize) -> CGFloat {
        guard area.width.isFinite, area.height.isFinite else { return 288 }
        // Aim for four columns and allow two rows below the controls. The compact
        // other-Space strip can scroll independently; its contents never change this size.
        let byWidth = (area.width - 32 - 3 * 20) / 4
        let rowHeight = (area.height - 160 - 24 - 20) / 2
        let byHeight = (rowHeight - 106) / 0.55 + 20
        return min(520, max(220, min(byWidth, byHeight).rounded(.down)))
    }

    func manualWidth(for display: String?) -> CGFloat? {
        guard let display, let value = defaults.dictionary(forKey: key)?[display] as? Double,
              value.isFinite, (220...520).contains(value) else { return nil }
        return CGFloat(value)
    }

    func width(for display: String?, area: CGSize) -> CGFloat {
        manualWidth(for: display) ?? Self.automaticWidth(in: area)
    }

    func setManualWidth(_ width: CGFloat?, for display: String?) {
        // If the system cannot identify a display, do not write a profile for a
        // transient screen number that might later belong to another monitor.
        guard let display else { return }
        var profiles = defaults.dictionary(forKey: key) ?? [:]
        if let width, width.isFinite {
            profiles[display] = Double(min(520, max(220, width.rounded())))
        } else {
            profiles.removeValue(forKey: display)
        }
        defaults.set(profiles, forKey: key)
    }
}

func overviewSizingTests() {
    let suite = "local.spacehop.sizing-test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let sizing = OverviewSizing(defaults: defaults)
    let laptop = CGSize(width: 1464, height: 860)
    let external = CGSize(width: 2512, height: 1370)
    let laptopAuto = sizing.width(for: "laptop", area: laptop)
    let externalAuto = sizing.width(for: "external", area: external)
    precondition(laptopAuto < externalAuto && externalAuto <= 520)
    precondition(GridMetrics(width: laptop.width, preferredWidth: laptopAuto).columns == 4)
    defaults.set(471, forKey: "overviewCardWidth")
    precondition(sizing.width(for: "laptop", area: laptop) == laptopAuto, "Legacy global size must not override automatic display sizes")
    sizing.setManualWidth(325, for: "laptop")
    sizing.setManualWidth(490, for: "external")
    let restarted = OverviewSizing(defaults: UserDefaults(suiteName: suite)!)
    precondition(restarted.width(for: "laptop", area: external) == 325)
    precondition(restarted.width(for: "external", area: laptop) == 490)
    restarted.setManualWidth(nil, for: "laptop")
    precondition(sizing.width(for: "laptop", area: laptop) == laptopAuto)
    precondition(sizing.width(for: "external", area: external) == 490, "Reset affects only the current monitor")
    precondition(sizing.width(for: "laptop", area: external) == externalAuto, "Automatic size follows changed resolution/scaling")
    sizing.setManualWidth(900, for: "laptop")
    precondition(sizing.manualWidth(for: "laptop") == 520)
    sizing.setManualWidth(nil, for: "laptop")
    defaults.set(["laptop": "invalid", "external": 999], forKey: "overviewCardWidthsByDisplay")
    precondition(sizing.manualWidth(for: "laptop") == nil && sizing.manualWidth(for: "external") == nil)
    sizing.setManualWidth(300, for: nil)
    precondition(sizing.manualWidth(for: nil) == nil)
    precondition(OverviewSizing.automaticWidth(in: CGSize(width: 900, height: 540)) == 220)
    precondition(OverviewSizing.automaticWidth(in: CGSize(width: CGFloat.infinity, height: 900)) == 288)
    print("PASS: automatic logical display sizes, per-monitor persistence, isolated reset, scaling changes and invalid preferences")
}
