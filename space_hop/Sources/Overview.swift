import AppKit
import ApplicationServices
import ScreenCaptureKit
import Darwin

struct OverviewWindow {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let bundleID: String
    let frame: CGRect
    var isMinimized = false
    var canMinimize = true
    var isOnScreen = true
    var key: String { "\(pid):\(id)" }
}

enum WindowCatalog {
    typealias AXWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
    private static let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let axWindowID: AXWindowID? = {
        guard let library, let pointer = dlsym(library, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(pointer, to: AXWindowID.self)
    }()

    static func element(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        guard let axWindowID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        return windows.first { window in
            var number: CGWindowID = 0
            return axWindowID(window, &number) == 0 && number == id
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }
    static func minimized(_ window: OverviewWindow) -> Bool? {
        guard let element = element(pid: window.pid, id: window.id) else { return nil }
        return (value(element, kAXMinimizedAttribute) as? NSNumber)?.boolValue
    }
    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    static func acceptsLayer(_ layer: Int, role: String?, subrole: String?) -> Bool {
        // Some ordinary document windows (e.g. Claude at layer -1) use a
        // nonzero WindowServer level. Accept AX-confirmed standard windows,
        // while keeping menu/status/utility surfaces out of the overview.
        layer == 0 || (role == kAXWindowRole && subrole == kAXStandardWindowSubrole)
    }
    static func acceptsOffSpaceFallback(layer: Int, title: String, hasSpace: Bool, hasAXElement: Bool) -> Bool {
        // AXWindows omits non-minimized windows on inactive Spaces. Only use
        // named ordinary WindowServer surfaces with confirmed Space membership.
        !hasAXElement && (layer == 0 || layer == -1) && hasSpace
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func current(includeOtherSpaces: Bool = false) -> [OverviewWindow] {
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let apps = Dictionary(regular.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var elements: [String: AXUIElement] = [:]
        // Minimized windows can disappear from the on-screen CG list. Read
        // each application's AX windows once, including those missing in CG.
        for app in regular {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            guard let windows = value(element, kAXWindowsAttribute) as? [AXUIElement], let axWindowID else { continue }
            for window in windows {
                var id: CGWindowID = 0
                if axWindowID(window, &id) == 0 { elements["\(app.processIdentifier):\(id)"] = window }
            }
        }
        let reader = SpaceReader()
        var result: [OverviewWindow] = []
        var seen = Set<String>()
        func append(id: CGWindowID, pid: pid_t, row: [String: Any]?, element: AXUIElement?) {
            let key = "\(pid):\(id)"
            guard !seen.contains(key), let app = apps[pid] else { return }
            let mini = element.flatMap { value($0, kAXMinimizedAttribute) as? NSNumber }?.boolValue ?? false
            let onScreen = (row?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            let standard = element.map { value($0, kAXRoleAttribute) as? String == kAXWindowRole
                && value($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole } ?? false
            let fallback = includeOtherSpaces && acceptsOffSpaceFallback(
                layer: (row?[kCGWindowLayer as String] as? NSNumber)?.intValue ?? Int.max,
                title: row?[kCGWindowName as String] as? String ?? "",
                hasSpace: !(reader.spaces(windowID: id) ?? []).isEmpty, hasAXElement: element != nil)
            guard mini || onScreen || (includeOtherSpaces && standard) || fallback else { return }
            let cgFrame = (row?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            let frame = mini ? element.flatMap { axFrame($0) } ?? cgFrame : cgFrame ?? element.flatMap { axFrame($0) }
            guard let frame, frame.width > 80, frame.height > 60 else { return }
            if !mini, (row?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 <= 0 { return }
            var title = row?[kCGWindowName as String] as? String ?? ""
            if title.isEmpty, let element { title = value(element, kAXTitleAttribute) as? String ?? "" }
            var settable: DarwinBoolean = false
            if let element { AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) }
            result.append(OverviewWindow(id: id, pid: pid, app: app.localizedName ?? "Приложение", title: title,
                bundleID: app.bundleIdentifier ?? "", frame: frame, isMinimized: mini, canMinimize: settable.boolValue, isOnScreen: onScreen))
            seen.insert(key)
        }
        for row in rows {
            guard let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            let element = elements["\(pid):\(id)"]
            let role = layer == 0 ? nil : element.flatMap { value($0, kAXRoleAttribute) as? String }
            let subrole = layer == 0 ? nil : element.flatMap { value($0, kAXSubroleAttribute) as? String }
            let fallback = includeOtherSpaces && acceptsOffSpaceFallback(layer: layer,
                title: row[kCGWindowName as String] as? String ?? "",
                hasSpace: !(reader.spaces(windowID: id) ?? []).isEmpty, hasAXElement: element != nil)
            guard acceptsLayer(layer, role: role, subrole: subrole) || fallback else { continue }
            append(id: id, pid: pid, row: row, element: element)
        }
        for (key, element) in elements where !seen.contains(key) {
            let parts = key.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let id = UInt32(parts[1]) else { continue }
            append(id: id, pid: pid, row: nil, element: element)
        }
        return result
    }

    @discardableResult
    static func setMinimized(_ minimized: Bool, window: OverviewWindow) -> Bool {
        let reader = SpaceReader()
        guard let space = reader.read()?.id, reader.contains(windowID: window.id, spaceID: space) == true,
              let element = element(pid: window.pid, id: window.id) else { return false }
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                            minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    static func liveKeys() -> Set<String> {
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(rows.compactMap { row in
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return "\(pid):\(id)"
        })
    }

    private static func belongsToCurrentSpace(_ window: OverviewWindow) -> Bool {
        let reader = SpaceReader()
        guard let space = reader.read()?.id else { return false }
        return reader.contains(windowID: window.id, spaceID: space) ?? !window.isMinimized
    }

    @discardableResult
    static func focus(_ window: OverviewWindow) -> Bool {
        // Revalidate against the current Space; never focus a stale thumbnail
        // that could unexpectedly take the user to another desktop.
        guard belongsToCurrentSpace(window), current(includeOtherSpaces: true).contains(where: { $0.key == window.key }),
              let element = element(pid: window.pid, id: window.id),
              let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return raised
    }

    @discardableResult
    static func close(_ window: OverviewWindow) -> Bool {
        // Press the close control of this exact window. The owning application
        // handles unsaved changes; no forced termination or synthetic Cmd+Q.
        guard belongsToCurrentSpace(window), current().contains(where: { $0.key == window.key }),
              let element = element(pid: window.pid, id: window.id) else { return false }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func quit(_ window: OverviewWindow) -> Bool {
        guard belongsToCurrentSpace(window), window.pid != ProcessInfo.processInfo.processIdentifier,
              current().contains(where: { $0.key == window.key }),
              let app = NSRunningApplication(processIdentifier: window.pid),
              app.bundleIdentifier == window.bundleID, app.activationPolicy == .regular else { return false }
        app.activate(options: [.activateIgnoringOtherApps])
        // Normal asynchronous termination preserves the app's save/cancel flow.
        return app.terminate()
    }

    static func focusedID(pid: pid_t) -> CGWindowID? {
        guard let axWindowID else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        let element = value as! AXUIElement
        var id: CGWindowID = 0
        return axWindowID(element, &id) == 0 ? id : nil
    }
}

enum AlphabeticalWindowOrder {
    static func projectName(_ window: OverviewWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if window.bundleID.lowercased().contains("jetbrains"),
           let separator = [" – ", " — ", " - "].compactMap({ title.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            return String(title[..<separator.lowerBound])
        }
        return title
    }
    static func sorted(_ windows: [OverviewWindow]) -> [OverviewWindow] {
        windows.sorted { left, right in
            // Natural, case-insensitive alphabetical order: "Window 2" before
            // "Window 10". IDs only break ties for identically named windows.
            for (a, b) in [(left.app, right.app), (left.bundleID, right.bundleID),
                           (projectName(left), projectName(right)), (left.title, right.title)] {
                let result = a.localizedStandardCompare(b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            if left.pid != right.pid { return left.pid < right.pid }
            return left.id < right.id
        }
    }
}

enum OverviewScope: String { case all, application }

// Convert the usable screen area to our flipped, screen-local coordinates.
func overviewSafeArea(screen: CGRect, visible: CGRect) -> CGRect {
    let usable = screen.intersection(visible)
    return CGRect(x: usable.minX - screen.minX, y: screen.maxY - usable.maxY,
                  width: usable.width, height: usable.height).insetBy(dx: 24, dy: 24)
}

struct GridMetrics {
    let columns: Int
    let cardWidth: CGFloat
    var cardHeight: CGFloat { previewHeight + 106 }
    var previewHeight: CGFloat { (cardWidth - 20) * 0.55 }
    let gap: CGFloat = 20
    init(width: CGFloat, preferredWidth: CGFloat = 288) {
        let available = max(120, width - 32)
        cardWidth = min(min(520, max(220, preferredWidth)), available)
        columns = max(1, Int((available + gap) / (cardWidth + gap)))
    }
    var gridWidth: CGFloat { CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap }
    func rect(index: Int) -> CGRect {
        CGRect(x: CGFloat(index % columns) * (cardWidth + gap),
               y: CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
    }
    func contentHeight(count: Int) -> CGFloat {
        let rows = (max(0, count) + columns - 1) / columns
        return rows == 0 ? 0 : CGFloat(rows) * (cardHeight + gap) - gap
    }
    func documentSize(count: Int, viewport: CGSize) -> CGSize {
        CGSize(width: viewport.width, height: max(viewport.height, contentHeight(count: count) + 24))
    }
    func centeredRect(index: Int, count: Int, document: CGSize) -> CGRect {
        let rowStart = (index / columns) * columns
        let rowCount = min(columns, count - rowStart)
        let rowWidth = CGFloat(rowCount) * cardWidth + CGFloat(max(0, rowCount - 1)) * gap
        var result = rect(index: index)
        result.origin.x += (document.width - rowWidth) / 2
        result.origin.y += max(12, (document.height - contentHeight(count: count)) / 2)
        return result
    }
}

// Choose by visible geometry: centered short rows do not share column indices.
func verticalSelection(from index: Int, step: Int, frames: [CGRect]) -> Int {
    guard frames.indices.contains(index), abs(step) == 1 else { return index }
    let origin = frames[index]
    let nextRow = frames.filter { ($0.midY - origin.midY) * CGFloat(step) > 0.5 }
        .min { abs($0.midY - origin.midY) < abs($1.midY - origin.midY) }
    guard let nextRow else { return index }
    var best = index
    var bestDistance = CGFloat.infinity
    for (candidate, frame) in frames.enumerated() where abs(frame.midY - nextRow.midY) < 0.5 {
        let distance = abs(frame.midX - origin.midX)
        // Equal distances keep the leftmost candidate in stable window order.
        if distance < bestDistance - 0.0001 { best = candidate; bestDistance = distance }
    }
    return best
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class OverviewPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { onKey?(event) }

    func isBackground(atWindowPoint point: NSPoint) -> Bool {
        guard let root = contentView else { return false }
        let local = root.convert(point, from: nil)
        guard root.bounds.contains(local) else { return false }
        // NSView.hitTest takes a point in its superview's coordinates.
        let superPoint = root.superview?.convert(point, from: nil) ?? point
        var hit = root.hitTest(superPoint)
        while let view = hit {
            if view is WindowCard || view is OtherSpaceCard { return false }
            if view is NSControl {
                if let label = view as? NSTextField, !label.isEditable, !label.isSelectable {
                    hit = view.superview
                    continue
                }
                return false
            }
            hit = view.superview
        }
        return true
    }
}

final class CardPreview: NSImageView {
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = imageScaling == .scaleNone ? 1
            : max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

class CardOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CardShade: CardOverlay {
    var bottom = false
    override func draw(_ dirtyRect: NSRect) {
        let gradient: NSGradient?
        if bottom {
            gradient = NSGradient(colorsAndLocations: (NSColor.clear, 0),
                                  (NSColor.black.withAlphaComponent(0.74), 0.4),
                                  (NSColor.black.withAlphaComponent(0.96), 1))
        } else {
            gradient = NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(0.90), 0),
                                  (NSColor.black.withAlphaComponent(0.65), 0.45),
                                  (NSColor.clear, 1))
        }
        gradient?.draw(from: NSPoint(x: bounds.midX, y: 0),
                       to: NSPoint(x: bounds.midX, y: bounds.height), options: [])
    }
}

enum CardColors {
    static let hover = NSColor(calibratedRed: 0.80, green: 0.70, blue: 0.34, alpha: 1)
    static let selected = NSColor(calibratedRed: 0.34, green: 0.68, blue: 0.46, alpha: 1)
    static let destructive = NSColor(calibratedRed: 0.72, green: 0.32, blue: 0.34, alpha: 1)
}

final class CardTint: CardOverlay {
    var color = CardColors.destructive.withAlphaComponent(0.10)
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

final class CardOutline: CardOverlay {
    var color = NSColor.white.withAlphaComponent(0.1)
    var width: CGFloat = 1
    var inset: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset + width / 2, dy: inset + width / 2),
                                xRadius: max(0, 15 - inset - width / 2), yRadius: max(0, 15 - inset - width / 2))
        path.lineWidth = width
        path.stroke()
    }
}

class CardActionButton: NSButton {
    var usesPowerSymbol: Bool { false }
    var usesMinimizeSymbol: Bool { false }
    var persistentHighlight = false { didSet { needsDisplay = true } }
    var accentColor: NSColor { CardColors.destructive }
    var onHoverChanged: ((Bool) -> Void)?
    private var pointerHoverEnabled = true
    override var isFlipped: Bool { true }
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet {
            needsDisplay = true
            if oldValue != hovered { onHoverChanged?(hovered) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty && !rect.isNull else { tracking = nil; hovered = false; return }
        let area = NSTrackingArea(rect: rect,
                                  options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
        if let window {
            hovered = pointerHoverEnabled && containsPointer(window.mouseLocationOutsideOfEventStream)
        }
    }

    func setPointerHover(enabled: Bool, atWindowPoint point: NSPoint?) {
        pointerHoverEnabled = enabled
        hovered = enabled && point.map { containsPointer($0) } == true
    }

    private func containsPointer(_ point: NSPoint) -> Bool {
        let local = convert(point, from: nil)
        return bounds.contains(local) && visibleRect.contains(local)
    }

    override func mouseEntered(with event: NSEvent) { hovered = pointerHoverEnabled && containsPointer(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        if hovered || pressed || persistentHighlight {
            accentColor.withAlphaComponent(pressed ? 0.75 : 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
        }
        let highlighted = hovered || pressed || persistentHighlight
        (usesMinimizeSymbol && highlighted ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : highlighted ? NSColor.white : NSColor.white.withAlphaComponent(isEnabled ? 0.8 : 0.3)).setStroke()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if usesMinimizeSymbol {
            let line = NSBezierPath()
            line.lineWidth = 2.3
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: center.x - 7, y: center.y))
            line.line(to: NSPoint(x: center.x + 7, y: center.y))
            line.stroke()
            return
        }
        if usesPowerSymbol {
            let power = NSBezierPath()
            power.lineWidth = 2
            power.lineCapStyle = .round
            power.appendArc(withCenter: center, radius: 7, startAngle: -50, endAngle: 230)
            power.move(to: NSPoint(x: center.x, y: center.y - 9))
            power.line(to: NSPoint(x: center.x, y: center.y - 1))
            power.stroke()
            return
        }
        let cross = NSBezierPath()
        cross.lineWidth = 2.3
        cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: center.x - 7, y: center.y - 7))
        cross.line(to: NSPoint(x: center.x + 7, y: center.y + 7))
        cross.move(to: NSPoint(x: center.x - 7, y: center.y + 7))
        cross.line(to: NSPoint(x: center.x + 7, y: center.y - 7))
        cross.stroke()
    }
}

final class WindowMinimizeButton: CardActionButton {
    override var usesMinimizeSymbol: Bool { true }
    override var accentColor: NSColor { CardColors.hover }
}
final class WindowCloseButton: CardActionButton {}
final class ApplicationQuitButton: CardActionButton {
    override var usesPowerSymbol: Bool { true }
}

final class WindowCard: NSView {
    private(set) var item: OverviewWindow
    let imageView = CardPreview()
    private let icon = NSImageView()
    private let topShade = CardShade()
    private let bottomShade = CardShade()
    private let quitTint = CardTint()
    private let outline = CardOutline()
    private let appLabel: NSTextField
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField?
    private let closeButton: WindowCloseButton
    private let minimizeButton: WindowMinimizeButton
    private let quitButton: ApplicationQuitButton
    var choose: (() -> Void)?
    var toggleMinimized: (() -> Void)?
    var closeWindow: (() -> Void)?
    var quitApplication: (() -> Void)?
    var onQuitHover: ((Bool) -> Void)?
    var quittingAppPreview = false { didSet { updateBorder() } }
    var selected = false { didSet { updateBorder() } }
    var isCurrentWindow = false { didSet { updateBorder() } }
    override var isFlipped: Bool { true }

    init(window: OverviewWindow, frame: CGRect, position: Int) {
        self.item = window
        appLabel = NSTextField(labelWithString: window.app)
        let title = window.title.isEmpty ? "Окно \(position + 1)" : window.title
        // Titles such as "project – file" have two independent lines, so a
        // long project name cannot push the file out of the visible caption.
        let separator = [" – ", " — ", " - "].compactMap { title.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        if let separator,
           !title[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !title[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titleLabel = NSTextField(labelWithString: title[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
            detailLabel = NSTextField(labelWithString: title[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            titleLabel = NSTextField(wrappingLabelWithString: title)
            detailLabel = nil
        }
        minimizeButton = WindowMinimizeButton(title: "", target: nil, action: nil)
        closeButton = WindowCloseButton(title: "", target: nil, action: nil)
        quitButton = ApplicationQuitButton(title: "", target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.96).cgColor
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor
        addSubview(imageView)
        quitTint.isHidden = true
        addSubview(quitTint)
        bottomShade.bottom = true
        addSubview(topShade)
        addSubview(bottomShade)
        icon.image = NSRunningApplication(processIdentifier: window.pid)?.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        appLabel.font = .systemFont(ofSize: 12, weight: .medium)
        appLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        appLabel.lineBreakMode = .byTruncatingTail
        addSubview(appLabel)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = detailLabel == nil ? 2 : 1
        if detailLabel == nil {
            titleLabel.cell?.wraps = true
            titleLabel.cell?.truncatesLastVisibleLine = true
        } else {
            titleLabel.lineBreakMode = .byTruncatingTail
        }
        titleLabel.toolTip = window.title
        addSubview(titleLabel)
        if let detailLabel {
            detailLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            detailLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
            detailLabel.lineBreakMode = .byTruncatingMiddle
            detailLabel.toolTip = window.title
            addSubview(detailLabel)
        }
        minimizeButton.target = self
        minimizeButton.action = #selector(pressMinimize)
        minimizeButton.isBordered = false
        addSubview(minimizeButton)
        updateMinimizeButton()
        closeButton.target = self
        closeButton.action = #selector(pressClose)
        closeButton.isBordered = false
        closeButton.toolTip = "Закрыть это окно (Cmd + W)"
        closeButton.setAccessibilityLabel("Закрыть окно: \(window.title)")
        addSubview(closeButton)
        quitButton.target = self
        quitButton.action = #selector(pressQuit)
        quitButton.isBordered = false
        quitButton.toolTip = "Завершить \(window.app) (Cmd + Q) · все окна приложения"
        quitButton.setAccessibilityLabel("Завершить \(window.app), закрыть все его окна")
        quitButton.onHoverChanged = { [weak self] hovered in self?.onQuitHover?(hovered) }
        addSubview(quitButton)
        addSubview(outline)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(window.app), \(window.title)")
        imageView.onPress = { [weak self] in self?.choose?() }
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.button)
        imageView.setAccessibilityLabel("Открыть окно: \(window.title)")
        updateBorder()
        layoutContents()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func accessibilityPerformPress() -> Bool { choose?(); return true }
    override func mouseDown(with event: NSEvent) { choose?() }
    @objc private func pressMinimize() { toggleMinimized?() }
    func setMinimized(_ minimized: Bool) {
        item.isMinimized = minimized
        updateMinimizeButton()
    }
    private func updateMinimizeButton() {
        minimizeButton.persistentHighlight = item.isMinimized
        minimizeButton.isEnabled = item.canMinimize
        minimizeButton.toolTip = item.isMinimized ? "Развернуть это окно" : "Свернуть это окно (Cmd + M)"
        minimizeButton.setAccessibilityLabel("\(item.isMinimized ? "Развернуть" : "Свернуть") окно: \(item.title)")
    }
    @objc private func pressClose() { closeWindow?() }
    @objc private func pressQuit() { quitApplication?() }
    func resize(to frame: CGRect) { self.frame = frame; layoutContents() }
    private func layoutContents() {
        icon.frame = NSRect(x: 12, y: 10, width: 20, height: 20)
        appLabel.frame = NSRect(x: 39, y: 11, width: max(1, bounds.width - 176), height: 18)
        quitButton.frame = NSRect(x: bounds.width - 127, y: 2, width: 36, height: 36)
        minimizeButton.frame = NSRect(x: bounds.width - 85, y: 2, width: 36, height: 36)
        closeButton.frame = NSRect(x: bounds.width - 43, y: 2, width: 36, height: 36)
        imageView.frame = bounds
        quitTint.frame = bounds
        topShade.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 72)
        bottomShade.frame = NSRect(x: 0, y: bounds.height - 90, width: bounds.width, height: 90)
        outline.frame = bounds
        titleLabel.frame = NSRect(x: 13, y: bounds.height - 56, width: bounds.width - 26,
                                 height: detailLabel == nil ? 44 : 21)
        detailLabel?.frame = NSRect(x: 13, y: bounds.height - 34, width: bounds.width - 26, height: 21)
    }
    func setPointerHover(enabled: Bool, atWindowPoint point: NSPoint? = nil) {
        minimizeButton.setPointerHover(enabled: enabled, atWindowPoint: point)
        closeButton.setPointerHover(enabled: enabled, atWindowPoint: point)
        quitButton.setPointerHover(enabled: enabled, atWindowPoint: point)
    }
    private func updateBorder() {
        outline.width = quittingAppPreview || selected || isCurrentWindow ? 2.5 : 1.5
        outline.color = isCurrentWindow ? CardColors.selected
            : quittingAppPreview ? CardColors.destructive
            : selected ? CardColors.hover
            : NSColor.white.withAlphaComponent(0.40)
        outline.needsDisplay = true
        quitTint.color = CardColors.destructive.withAlphaComponent(0.10)
        quitTint.isHidden = !quittingAppPreview
        quitTint.needsDisplay = true
    }
    func placeholder() {
        let icon = NSRunningApplication(processIdentifier: item.pid)?.icon?.copy() as? NSImage
        icon?.size = NSSize(width: 64, height: 64)
        imageView.image = icon
        imageView.imageScaling = .scaleNone
    }
}

struct OtherSpaceGroup {
    let id: UInt64
    let number: Int
    let windows: [OverviewWindow]
}

func otherSpaceGroups(catalog: [OverviewWindow], state: SpaceState,
                      contains: (CGWindowID, UInt64) -> Bool) -> [OtherSpaceGroup] {
    var assigned = Set(catalog.filter { contains($0.id, state.id) }.map(\.key))
    return state.ids.enumerated().compactMap { index, id in
        guard id != state.id else { return nil }
        let windows = AlphabeticalWindowOrder.sorted(catalog.filter { !assigned.contains($0.key) && contains($0.id, id) })
        assigned.formUnion(windows.map(\.key))
        return windows.isEmpty ? nil : OtherSpaceGroup(id: id, number: index + 1, windows: windows)
    }
}

// Compact, non-destructive navigation cards. Snapshots come from the RAM cache.
final class OtherSpaceCard: NSView {
    let item: OverviewWindow
    let spaceID: UInt64
    let imageView = CardPreview()
    private let outline = CardOutline()
    var choose: (() -> Void)?
    var selected = false { didSet {
        outline.width = selected ? 2.5 : 1.5
        outline.color = selected ? CardColors.hover : NSColor.white.withAlphaComponent(0.40)
        outline.needsDisplay = true
    } }
    override var isFlipped: Bool { true }
    init(window: OverviewWindow, spaceID: UInt64, image: NSImage?, frame: CGRect) {
        item = window; self.spaceID = spaceID
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        imageView.frame = bounds
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        imageView.image = image ?? icon
        imageView.imageScaling = image == nil ? .scaleNone : .scaleProportionallyUpOrDown
        if image == nil { imageView.image = icon?.copy() as? NSImage; imageView.image?.size = NSSize(width: 36, height: 36) }
        imageView.onPress = { [weak self] in self?.choose?() }
        addSubview(imageView)
        let topShade = CardShade(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 44))
        addSubview(topShade)
        let appIcon = NSImageView(frame: NSRect(x: 9, y: 8, width: 20, height: 20))
        appIcon.image = icon
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.setAccessibilityElement(false)
        addSubview(appIcon)
        let shade = CardShade(frame: NSRect(x: 0, y: bounds.height - 55, width: bounds.width, height: 55))
        shade.bottom = true; addSubview(shade)
        let app = NSTextField(labelWithString: window.app)
        app.font = .systemFont(ofSize: 11, weight: .semibold); app.textColor = .white
        app.lineBreakMode = .byTruncatingTail
        app.frame = NSRect(x: 9, y: bounds.height - 38, width: bounds.width - 18, height: 16)
        addSubview(app)
        let title = NSTextField(labelWithString: window.title.isEmpty ? window.app : window.title)
        title.font = .systemFont(ofSize: 11); title.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = NSRect(x: 9, y: bounds.height - 21, width: bounds.width - 18, height: 16)
        addSubview(title)
        outline.frame = bounds; outline.width = 1.5; outline.color = NSColor.white.withAlphaComponent(0.40)
        addSubview(outline)
        toolTip = "\(window.app) — \(window.title)"
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Открыть \(window.app), \(window.title), на другом рабочем столе")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func mouseDown(with event: NSEvent) { choose?() }
    override func accessibilityPerformPress() -> Bool { choose?(); return true }
}

final class OverviewController: NSObject {
    private(set) var panel: OverviewPanel?
    private(set) var windows: [OverviewWindow] = []
    private var cards: [WindowCard] = []
    private var otherCards: [OtherSpaceCard] = []
    private var otherGroups: [OtherSpaceGroup] = []
    private var otherScroll: NSScrollView?
    private var sourceDisplay: String?
    var onNavigate: ((OverviewWindow, UInt64, String) -> Void)?
    private var selected = 0
    private var hoveredQuitPID: pid_t?
    private var metrics = GridMetrics(width: 1200)
    private var scroll: NSScrollView?
    private var sizeLabel: NSTextField?
    private var sizeSlider: NSSlider?
    private var autoSizeButton: NSButton?
    private let sizing: OverviewSizing
    private var sizeDisplayKey: String?
    private var sizeDisplayName = ""
    private var manualSize = false
    private var transparencyLabel: NSTextField?
    private var preferredWidth: CGFloat = 288
    private var backgroundOpacity = CGFloat(UserDefaults.standard.object(forKey: "overviewBackgroundOpacity") as? Double ?? 0.55)
    private var generation = UUID()
    private var pendingClose: OverviewWindow?
    private var pendingMinimize: OverviewWindow?
    private var previewCache: [String: NSImage] = [:]
    private var previewRequests: [String: UUID] = [:]
    private var previewFailures: [String: String] = [:]
    private var subtitleLabel: NSTextField?
    private var emptyLabel: NSTextField?
    private let reader = SpaceReader()
    private var sourceSpace: UInt64?
    private(set) var scope: OverviewScope = .all
    private var safeArea = CGRect.zero
    private var applicationPID: pid_t?
    private var originalApp: NSRunningApplication?
    private var originalWindow: OverviewWindow?
    private var mouseMonitor: Any?
    private var outsideMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var pointerIndex: Int?
    private var hoverSuppressed = false
    private var hoverResumePoint: NSPoint?
    private var spaceObserver: NSObjectProtocol?
    var isVisible: Bool { panel?.isVisible == true }
    var onFocus: ((Bool) -> Void)?

    init(sizing: OverviewSizing = OverviewSizing()) {
        self.sizing = sizing
        super.init()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            self?.dismiss(restore: false)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, self.isVisible,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                if self.pendingMinimize != nil || self.pendingClose?.pid == app.processIdentifier { return }
                self.dismiss(restore: false)
            }
    }
    deinit {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func toggle(scope: OverviewScope = .all) {
        if isVisible && self.scope == scope { dismiss() } else { show(scope: scope) }
    }

    func show(scope: OverviewScope = .all) {
        if isVisible && self.scope == scope { return }
        // Switching modes replaces one panel, preserving the app/window that
        // was active before opening either overview.
        if isVisible {
            let app = originalApp, window = originalWindow, space = sourceSpace
            dismiss(restore: false)
            originalApp = app; originalWindow = window; sourceSpace = space
        } else {
            originalApp = NSWorkspace.shared.frontmostApplication
            originalWindow = nil
            sourceSpace = reader.read()?.id
        }
        self.scope = scope
        applicationPID = originalApp?.processIdentifier
        let state = reader.read()
        sourceDisplay = state?.display
        let catalog = WindowCatalog.current(includeOtherSpaces: true)
        let scopedCatalog = scope == .application ? catalog.filter { $0.pid == applicationPID } : catalog
        otherGroups = state.map { state in
            otherSpaceGroups(catalog: scopedCatalog, state: state) { reader.contains(windowID: $0, spaceID: $1) == true }
        } ?? []
        let visible = catalog.filter { window in
            guard let sourceSpace else { return window.isOnScreen || window.isMinimized }
            return reader.contains(windowID: window.id, spaceID: sourceSpace) ?? window.isOnScreen
        }
        let live = WindowCatalog.liveKeys().union(catalog.map(\.key))
        previewCache = previewCache.filter { live.contains($0.key) }
        let ordered = AlphabeticalWindowOrder.sorted(visible)
        windows = scope == .application ? ordered.filter { $0.pid == applicationPID } : ordered
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main!
        let frame = screen.frame
        safeArea = overviewSafeArea(screen: frame, visible: screen.visibleFrame)
        sizeDisplayKey = OverviewSizing.displayKey(screen)
        sizeDisplayName = screen.localizedName
        preferredWidth = sizing.width(for: sizeDisplayKey, area: safeArea.size)
        manualSize = sizing.manualWidth(for: sizeDisplayKey) != nil
        let panel = OverviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = scope == .all ? "SpaceHop — окна текущего Space" : "SpaceHop — окна приложения"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: backgroundOpacity)
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let root = FlippedView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = root
        let title = NSTextField(labelWithString: scope == .all ? "Окна текущего рабочего стола" : "Окна \(originalApp?.localizedName ?? "приложения")")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: safeArea.minX + 12, y: safeArea.minY, width: safeArea.width - 90, height: 36)
        root.addSubview(title)
        let subtitle = NSTextField(labelWithString: "\(windows.count) окон  ·  по алфавиту  ·  одинаковые карточки")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        subtitle.frame = NSRect(x: safeArea.minX + 13, y: safeArea.minY + 38, width: safeArea.width - 80, height: 23)
        root.addSubview(subtitle)
        subtitleLabel = subtitle
        addControls(to: root, origin: NSPoint(x: safeArea.minX - 36, y: safeArea.minY - 35))
        let close = NSButton(title: "✕", target: self, action: #selector(closeOverview))
        close.isBordered = false
        close.font = .systemFont(ofSize: 23, weight: .light)
        close.frame = NSRect(x: safeArea.maxX - 52, y: safeArea.minY + 8, width: 40, height: 38)
        close.setAccessibilityLabel("Закрыть обзор")
        root.addSubview(close)
        let scroll = NSScrollView(frame: NSRect(x: safeArea.minX, y: safeArea.minY + 110, width: safeArea.width, height: max(80, safeArea.height - 160 - (otherGroups.isEmpty ? 0 : 190))))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        metrics = GridMetrics(width: scroll.contentSize.width, preferredWidth: preferredWidth)
        let documentSize = metrics.documentSize(count: windows.count, viewport: scroll.contentSize)
        let document = FlippedView(frame: NSRect(origin: .zero, size: documentSize))
        cards = windows.enumerated().map { index, window in
            let cardFrame = metrics.centeredRect(index: index, count: windows.count, document: documentSize)
            let card = WindowCard(window: window, frame: cardFrame, position: index)
            document.addSubview(card)
            card.placeholder()
            if let image = previewCache[window.key] {
                card.imageView.image = image
                card.imageView.imageScaling = .scaleProportionallyUpOrDown
            }
            return card
        }
        bindCardActions()
        scroll.documentView = document
        root.addSubview(scroll)
        self.scroll = scroll
        addOtherSpaces(to: root, below: scroll.frame.maxY + 8)
        do {
            let empty = NSTextField(labelWithString: "На этом рабочем столе нет открытых окон")
            empty.font = .systemFont(ofSize: 18)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: safeArea.minX + 16, y: safeArea.minY + 155, width: safeArea.width - 32, height: 35)
            empty.isHidden = !windows.isEmpty
            root.addSubview(empty)
            emptyLabel = empty
        }
        let footer = NSTextField(labelWithString: "← ↑ ↓ →  выбрать       Enter  открыть       Esc  вернуться")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        footer.frame = NSRect(x: safeArea.minX + 12, y: safeArea.maxY - 28, width: safeArea.width - 24, height: 23)
        root.addSubview(footer)
        if !CGPreflightScreenCaptureAccess() {
            let button = NSButton(title: "Разрешить превью окон…", target: self, action: #selector(requestPreviews))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: safeArea.maxX - 275, y: safeArea.maxY - 37, width: 263, height: 34)
            root.addSubview(button)
        }
        selected = 0
        if let pid = originalApp?.processIdentifier, let id = WindowCatalog.focusedID(pid: pid),
           let index = windows.firstIndex(where: { $0.pid == pid && $0.id == id }) {
            selected = index
            originalWindow = windows[index]
        }
        updateSelection()
        panel.onKey = { [weak self] event in self?.key(event) }
        self.panel = panel
        generation = UUID()
        hoverSuppressed = false
        hoverResumePoint = nil
        pointerIndex = nil
        // Global clicks include Dock clicks on an already-active app, which
        // may not generate another application-activation notification.
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismiss(restore: false)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.type == .mouseMoved {
                self.resumePointerHover(at: event.locationInWindow)
                return event
            }
            guard panel.isBackground(atWindowPoint: event.locationInWindow) else { return event }
            self.returnToCurrentWindow()
            return nil
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
        resumePointerHover(at: panel.mouseLocationOutsideOfEventStream, force: true)
        if CGPreflightScreenCaptureAccess() { loadPreviews(generation: generation) }
    }

    func dismiss(restore: Bool = true) {
        generation = UUID()
        pendingClose = nil
        pendingMinimize = nil
        previewRequests.removeAll(); previewFailures.removeAll()
        subtitleLabel = nil; emptyLabel = nil
        sizeSlider = nil; sizeLabel = nil; autoSizeButton = nil; transparencyLabel = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        cards.removeAll()
        otherCards.removeAll(); otherGroups.removeAll(); otherScroll = nil
        hoveredQuitPID = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        outsideMouseMonitor = nil
        pointerIndex = nil
        if restore { originalApp?.activate(options: [.activateIgnoringOtherApps]) }
        originalApp = nil
        originalWindow = nil
    }

    @objc private func closeOverview() { dismiss() }
    @objc func requestPreviews() {
        dismiss()
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func addOtherSpaces(to root: NSView, below y: CGFloat) {
        guard !otherGroups.isEmpty else { return }
        let title = NSTextField(labelWithString: "Другие рабочие столы · нажми на окно, чтобы перейти")
        title.font = .systemFont(ofSize: 12); title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: safeArea.minX + 16, y: y, width: safeArea.width - 32, height: 20)
        root.addSubview(title)
        let strip = NSScrollView(frame: NSRect(x: safeArea.minX, y: y + 24, width: safeArea.width, height: 152))
        strip.drawsBackground = false; strip.hasHorizontalScroller = true
        strip.hasVerticalScroller = false; strip.scrollerStyle = .overlay
        strip.verticalScrollElasticity = .none
        let document = FlippedView(frame: .zero)
        var x: CGFloat = 16
        for group in otherGroups {
            let label = NSTextField(labelWithString: "Рабочий стол \(group.number)")
            label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabelColor
            let width = CGFloat(group.windows.count) * 176 - 12
            label.frame = NSRect(x: x, y: 0, width: max(164, width), height: 19)
            document.addSubview(label)
            for window in group.windows {
                let card = OtherSpaceCard(window: window, spaceID: group.id, image: previewCache[window.key],
                                          frame: NSRect(x: x, y: 24, width: 164, height: 116))
                card.choose = { [weak self] in self?.chooseOther(window, spaceID: group.id) }
                document.addSubview(card); otherCards.append(card)
                x += 176
            }
            x += 20
        }
        document.setFrameSize(NSSize(width: max(strip.contentSize.width, x - 20 + 4), height: 144))
        strip.documentView = document; root.addSubview(strip); otherScroll = strip
    }

    private func chooseOther(_ window: OverviewWindow, spaceID: UInt64) {
        guard let display = sourceDisplay, let state = reader.read(),
              state.id == sourceSpace, state.display == display,
              reader.contains(windowID: window.id, spaceID: spaceID) == true else { dismiss(restore: false); return }
        let navigate = onNavigate
        dismiss(restore: false)
        navigate?(window, spaceID, display)
    }

    func choose(_ index: Int) {
        guard windows.indices.contains(index), reader.read()?.id == sourceSpace else { dismiss(); return }
        let window = windows[index]
        dismiss(restore: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            let focused = WindowCatalog.focus(window)
            self?.onFocus?(focused)
        }
    }

    func returnToCurrentWindow() {
        guard reader.read()?.id == sourceSpace else { dismiss(restore: false); return }
        if let originalWindow, let index = windows.firstIndex(where: { $0.key == originalWindow.key }) {
            choose(index)
        } else { dismiss() }
    }

    private func bindCardActions() {
        for (index, card) in cards.enumerated() {
            card.choose = { [weak self] in self?.choose(index) }
            card.toggleMinimized = { [weak self] in self?.toggleMinimized(index) }
            card.closeWindow = { [weak self] in self?.closeWindow(index) }
            card.quitApplication = { [weak self] in self?.quitApplication(index) }
            let pid = card.item.pid
            card.onQuitHover = { [weak self] hovered in self?.highlightApplication(pid: pid, hovered: hovered) }
        }
    }

    func toggleMinimized(_ index: Int) {
        guard pendingClose == nil, pendingMinimize == nil, isVisible, windows.indices.contains(index),
              windows[index].canMinimize, reader.read()?.id == sourceSpace else { return }
        let target = windows[index]
        guard let actual = WindowCatalog.minimized(target) else { NSSound.beep(); return }
        let requested = !actual
        pendingMinimize = target
        guard WindowCatalog.setMinimized(requested, window: target) else {
            pendingMinimize = nil; NSSound.beep(); return
        }
        let token = generation
        // Allow the native minimize/restore animation and resulting activation
        // notifications to settle while keeping the same overview panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.waitForMinimize(target, requested: requested, token: token, attempts: 6)
        }
    }

    private func waitForMinimize(_ target: OverviewWindow, requested: Bool, token: UUID, attempts: Int) {
        guard generation == token, isVisible, pendingMinimize?.key == target.key,
              reader.read()?.id == sourceSpace else { return }
        if let actual = WindowCatalog.minimized(target), actual == requested {
            if let index = windows.firstIndex(where: { $0.key == target.key }) {
                windows[index].isMinimized = actual
                cards[index].setMinimized(actual)
            }
            if originalWindow?.key == target.key && requested {
                originalWindow = nil
                if let pid = originalApp?.processIdentifier, let focused = WindowCatalog.focusedID(pid: pid) {
                    originalWindow = windows.first { $0.pid == pid && $0.id == focused && !$0.isMinimized }
                }
            }
            pendingMinimize = nil
            updateSelection(scroll: false)
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(panel)
            if !requested, CGPreflightScreenCaptureAccess() { loadPreviews(generation: token) }
            return
        }
        guard attempts > 0 else { pendingMinimize = nil; NSSound.beep(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForMinimize(target, requested: requested, token: token, attempts: attempts - 1)
        }
    }

    func closeWindow(_ index: Int) {
        guard pendingClose == nil, pendingMinimize == nil else { return }
        guard isVisible, windows.indices.contains(index), reader.read()?.id == sourceSpace else { dismiss(); return }
        let target = windows[index]
        pendingClose = target
        // AX presses the exact window's close button in the background. Keep
        // this panel and its previews alive instead of hiding/reopening it.
        let requested = WindowCatalog.close(target)
        waitForClose(target, token: generation, attempts: requested ? 6 : 0)
    }

    private func waitForClose(_ target: OverviewWindow, token: UUID, attempts: Int) {
        guard generation == token, isVisible, pendingClose?.key == target.key,
              reader.read()?.id == sourceSpace else { return }
        if WindowCatalog.element(pid: target.pid, id: target.id) == nil {
            pendingClose = nil
            removeClosedWindow(target)
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(panel)
            return
        }
        guard attempts > 0 else {
            // A save dialog or a declined close keeps the window alive. Hand
            // control to that application and never reopen over its dialog.
            dismiss(restore: false)
            if !WindowCatalog.focus(target) { NSSound.beep() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForClose(target, token: token, attempts: attempts - 1)
        }
    }

    private func removeClosedWindow(_ target: OverviewWindow) {
        guard let index = windows.firstIndex(where: { $0.key == target.key }) else { return }
        let selectionKey = windows.indices.contains(selected) ? windows[selected].key : nil
        previewCache.removeValue(forKey: target.key)
        windows.remove(at: index)
        cards.remove(at: index).removeFromSuperview()
        selected = selectionKey.flatMap { key in windows.firstIndex { $0.key == key } }
            ?? min(index, max(0, windows.count - 1))
        if originalWindow?.key == target.key {
            originalWindow = nil
            if let pid = originalApp?.processIdentifier, let focused = WindowCatalog.focusedID(pid: pid) {
                originalWindow = windows.first { $0.pid == pid && $0.id == focused }
            }
        }
        hoveredQuitPID = nil
        for card in cards { card.quittingAppPreview = false }
        bindCardActions()
        subtitleLabel?.stringValue = "\(windows.count) окон  ·  по алфавиту  ·  одинаковые карточки"
        emptyLabel?.isHidden = !windows.isEmpty
        relayout()
        // Layout shifts must not turn the old close-button hover into a red
        // highlight on another card, or move a keyboard selection.
        for card in cards { card.setPointerHover(enabled: false) }
        if !hoverSuppressed, let panel {
            resumePointerHover(at: panel.mouseLocationOutsideOfEventStream, force: true)
        }
    }

    private func highlightApplication(pid: pid_t, hovered: Bool) {
        if hovered { hoveredQuitPID = pid }
        else if hoveredQuitPID == pid { hoveredQuitPID = nil }
        for card in cards { card.quittingAppPreview = card.item.pid == hoveredQuitPID }
    }

    func quitApplication(_ index: Int) {
        guard windows.indices.contains(index), reader.read()?.id == sourceSpace else { dismiss(); return }
        let target = windows[index]
        let space = sourceSpace
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == target.bundleID else { NSSound.beep(); return }
        dismiss(restore: false)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.generation == token, self.reader.read()?.id == space else { return }
            _ = WindowCatalog.focus(target)
            guard WindowCatalog.quit(target) else { NSSound.beep(); return }
            self.waitForQuit(app, space: space, token: token, attempts: 20)
        }
    }

    private func waitForQuit(_ app: NSRunningApplication, space: UInt64?, token: UUID, attempts: Int) {
        guard generation == token, !isVisible, reader.read()?.id == space else { return }
        if app.isTerminated { show(); return }
        // Leave native save dialogs visible. A cancelled or delayed quit does
        // not cause the grid to unexpectedly reopen much later.
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForQuit(app, space: space, token: token, attempts: attempts - 1)
        }
    }

    private func addControls(to root: NSView, origin: NSPoint) {
        let oldSubviews = Set(root.subviews.map { ObjectIdentifier($0) })
        defer {
            for view in root.subviews where !oldSubviews.contains(ObjectIdentifier(view)) {
                view.setFrameOrigin(NSPoint(x: view.frame.minX + origin.x, y: view.frame.minY + origin.y))
            }
        }
        func label(_ text: String, x: CGFloat, width: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            field.frame = NSRect(x: x, y: 109, width: width, height: 20)
            root.addSubview(field)
            return field
        }
        _ = label("Размер", x: 49, width: 57)
        let size = NSSlider(value: Double(preferredWidth), minValue: 220, maxValue: 520, target: self, action: #selector(changeSize(_:)))
        size.isContinuous = true
        size.frame = NSRect(x: 110, y: 104, width: 156, height: 26)
        size.setAccessibilityLabel("Размер карточек")
        root.addSubview(size)
        sizeSlider = size
        sizeLabel = label("\(Int(preferredWidth))", x: 274, width: 42)
        let automatic = NSButton(title: "Авто", target: self, action: #selector(resetSize))
        automatic.bezelStyle = .rounded
        automatic.frame = NSRect(x: 320, y: 104, width: 60, height: 26)
        automatic.setAccessibilityLabel("Автоматический размер карточек на этом экране")
        root.addSubview(automatic)
        autoSizeButton = automatic
        syncSizeControls()
        _ = label("Прозрачность", x: 404, width: 103)
        let transparency = NSSlider(value: Double(1 - backgroundOpacity), minValue: 0.15, maxValue: 0.8,
                                    target: self, action: #selector(changeTransparency(_:)))
        transparency.isContinuous = true
        transparency.frame = NSRect(x: 512, y: 104, width: 145, height: 26)
        transparency.setAccessibilityLabel("Прозрачность фона")
        root.addSubview(transparency)
        transparencyLabel = label("\(Int(((1 - backgroundOpacity) * 100).rounded()))%", x: 666, width: 45)
    }

    @objc private func changeSize(_ sender: NSSlider) {
        preferredWidth = CGFloat(sender.doubleValue.rounded())
        sizing.setManualWidth(preferredWidth, for: sizeDisplayKey)
        manualSize = true
        syncSizeControls()
        relayout()
        panel?.makeFirstResponder(panel)
    }

    @objc private func resetSize() {
        sizing.setManualWidth(nil, for: sizeDisplayKey)
        manualSize = false
        preferredWidth = OverviewSizing.automaticWidth(in: safeArea.size)
        syncSizeControls()
        relayout()
        panel?.makeFirstResponder(panel)
    }

    private func syncSizeControls() {
        sizeSlider?.doubleValue = Double(preferredWidth)
        sizeLabel?.stringValue = "\(Int(preferredWidth))"
        autoSizeButton?.isEnabled = manualSize
        autoSizeButton?.toolTip = manualSize ? "Вернуть автоматический размер: \(sizeDisplayName)" : "Автоматический размер: \(sizeDisplayName)"
        sizeSlider?.toolTip = "Размер карточек для экрана «\(sizeDisplayName)». \(manualSize ? "Ручная настройка" : "Автоматически")"
    }

    @objc private func changeTransparency(_ sender: NSSlider) {
        backgroundOpacity = CGFloat(1 - sender.doubleValue)
        UserDefaults.standard.set(Double(backgroundOpacity), forKey: "overviewBackgroundOpacity")
        transparencyLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
        panel?.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: backgroundOpacity)
        panel?.makeFirstResponder(panel)
    }

    private func relayout() {
        guard panel != nil, let scroll, let document = scroll.documentView else { return }
        metrics = GridMetrics(width: scroll.contentSize.width, preferredWidth: preferredWidth)
        let documentSize = metrics.documentSize(count: cards.count, viewport: scroll.contentSize)
        document.setFrameSize(documentSize)
        for (index, card) in cards.enumerated() {
            let rect = metrics.centeredRect(index: index, count: cards.count, document: documentSize)
            card.resize(to: rect)
        }
        updateSelection()
    }

    private func suppressPointerHover() {
        hoverSuppressed = true
        pointerIndex = nil
        hoverResumePoint = panel?.mouseLocationOutsideOfEventStream
        for card in cards { card.setPointerHover(enabled: false) }
        for card in otherCards { card.selected = false }
    }

    private func resumePointerHover(at point: NSPoint, force: Bool = false) {
        if hoverSuppressed, !force, let previous = hoverResumePoint,
           abs(point.x - previous.x) < 0.5 && abs(point.y - previous.y) < 0.5 { return }
        let wasKeyboard = hoverSuppressed
        hoverSuppressed = false
        hoverResumePoint = nil
        let hovered = cards.firstIndex { card in
            card.bounds.intersection(card.visibleRect).contains(card.convert(point, from: nil))
        }
        let otherHovered = otherCards.first { $0.bounds.intersection($0.visibleRect).contains($0.convert(point, from: nil)) }
        for card in otherCards { card.selected = card === otherHovered }
        let changed = pointerIndex != hovered
        pointerIndex = hovered
        if let hovered { selected = hovered }
        if force || wasKeyboard {
            for card in cards { card.setPointerHover(enabled: true, atWindowPoint: point) }
        }
        if force || changed || wasKeyboard { updateSelection(scroll: false) }
    }

    private func key(_ event: NSEvent) {
        if [UInt16(123), 124, 125, 126, 48].contains(event.keyCode) { suppressPointerHover() }
        switch event.keyCode {
        case 53: dismiss()
        case 36, 76: choose(selected)
        case 123: selected = max(0, selected - 1); updateSelection()
        case 124: selected = min(max(0, cards.count - 1), selected + 1); updateSelection()
        case 126: selected = verticalSelection(from: selected, step: -1, frames: cards.map(\.frame)); updateSelection()
        case 125: selected = verticalSelection(from: selected, step: 1, frames: cards.map(\.frame)); updateSelection()
        case 48: selected = (selected + (event.modifierFlags.contains(.shift) ? -1 : 1) + max(1, cards.count)) % max(1, cards.count); updateSelection()
        default: break
        }
    }

    private func updateSelection(scroll scrollSelected: Bool = true) {
        for (index, card) in cards.enumerated() {
            card.isCurrentWindow = card.item.key == originalWindow?.key
            card.selected = hoverSuppressed ? index == selected : index == pointerIndex
        }
        if scrollSelected, cards.indices.contains(selected) { cards[selected].scrollToVisible(cards[selected].bounds) }
    }

    private func loadPreviews(generation token: UUID) {
        guard #available(macOS 14.0, *) else { return }
        // A minimized window has no reliable live surface. Its last in-memory
        // image stays on the card; it must never block visible-window captures.
        let targets = windows.filter { !$0.isMinimized }
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                  let self, self.generation == token, self.isVisible else { return }
            for target in targets {
                guard self.generation == token, self.isVisible else { return }
                guard self.previewRequests[target.key] == nil,
                      let card = self.cards.first(where: { $0.item.key == target.key }), !card.item.isMinimized,
                      let window = content.windows.first(where: { $0.windowID == target.id }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1400 / max(1, window.frame.width), 900 / max(1, window.frame.height))
                config.width = max(2, Int(window.frame.width * scale))
                config.height = max(2, Int(window.frame.height * scale))
                config.showsCursor = false
                config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let request = UUID()
                self.previewRequests[target.key] = request
                // Each snapshot has its own task. No awaiting inside the
                // submission loop: a stalled capture cannot hold up another.
                Task { @MainActor [weak self] in
                    var image: CGImage?
                    var failure: String?
                    do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
                    catch { failure = "\((error as NSError).domain):\((error as NSError).code)" }
                    guard let self, self.previewRequests[target.key] == request else { return }
                    self.previewRequests.removeValue(forKey: target.key)
                    guard self.generation == token, self.isVisible,
                          let card = self.cards.first(where: { $0.item.key == target.key }) else { return }
                    guard let image else {
                        self.previewFailures[target.key] = failure ?? "no-image"
                        return
                    }
                    self.previewFailures.removeValue(forKey: target.key)
                    card.imageView.imageScaling = .scaleProportionallyUpOrDown
                    let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    card.imageView.image = preview
                    self.previewCache[target.key] = preview
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.generation == token, self.previewRequests[target.key] == request else { return }
                    self.previewRequests.removeValue(forKey: target.key)
                    self.previewFailures[target.key] = "timeout"
                }
            }
        }
    }

    func previewReport() -> [String: Any] {
        let normal = cards.filter { !$0.item.isMinimized }
        let missing = normal.filter { $0.imageView.imageScaling != .scaleProportionallyUpOrDown }.map { $0.item.key }
        return ["success": isVisible && missing.isEmpty, "visibleWindowCount": normal.count,
                "visiblePreviewsLoaded": normal.count - missing.count, "missingVisibleKeys": missing,
                "pendingKeys": Array(previewRequests.keys).sorted(), "failures": previewFailures,
                "minimizedWithoutCachedPreview": cards.filter { $0.item.isMinimized && $0.imageView.imageScaling == .scaleNone }.count,
                "minimizedPreviewRequests": cards.filter { $0.item.isMinimized && previewRequests[$0.item.key] != nil }.count,
                "overview": report()]
    }

    // Explicit integration-check entry point; settings are restored afterward.
    func verifyControls() -> [String: Any] {
        let oldWidth = preferredWidth, oldOpacity = backgroundOpacity
        let oldManualSize = manualSize, oldSavedWidth = sizing.manualWidth(for: sizeDisplayKey)
        let oldKeys = windows.map(\.key), oldSelected = selected
        let images = cards.map { $0.imageView.image }
        let size = NSSlider(value: 220, minValue: 220, maxValue: 520, target: nil, action: nil)
        changeSize(size)
        let small = metrics.columns
        size.doubleValue = 520
        changeSize(size)
        let large = metrics.columns
        let margins = safeMargins()
        let centered = centeredGrid()
        let transparency = NSSlider(value: 0.7, minValue: 0.15, maxValue: 0.8, target: nil, action: nil)
        changeTransparency(transparency)
        let opacityChanged = abs((panel?.backgroundColor.alphaComponent ?? 1) - 0.3) < 0.001
        let retained = zip(images, cards).allSatisfy { $0.0 === $0.1.imageView.image }
        let stable = windows.map(\.key) == oldKeys && selected == oldSelected
        let equal = cards.allSatisfy { $0.frame.size == CGSize(width: metrics.cardWidth, height: metrics.cardHeight) }
        sizing.setManualWidth(oldSavedWidth, for: sizeDisplayKey)
        preferredWidth = oldWidth
        manualSize = oldManualSize
        syncSizeControls()
        relayout()
        transparency.doubleValue = Double(1 - oldOpacity)
        changeTransparency(transparency)
        return ["success": small > large && stable && retained && equal && opacityChanged && margins && centered,
                "centeredAtLargestSize": centered, "safeMarginsAtLargestSize": margins, "smallColumns": small, "largeColumns": large, "orderAndSelectionRetained": stable,
                "previewsRetained": retained, "equalCardSizes": equal, "opacityChanged": opacityChanged]
    }

    func verifyBackgroundClick(completion: @escaping ([String: Any]) -> Void) {
        guard let panel, let root = panel.contentView, let expected = originalWindow else {
            completion(["success": false, "reason": "Original window unavailable"]); return
        }
        if cards.count > 1 { selected = (selected + 1) % cards.count; updateSelection() }
        let changedSelection = cards.count > 1 && windows[selected].key != expected.key
        let backgroundPoint = root.convert(NSPoint(x: 10, y: root.bounds.midY), to: nil)
        let classified = panel.isBackground(atWindowPoint: backgroundPoint)
        let controls = root.subviews.compactMap { $0 as? NSControl }.filter { !($0 is NSTextField) }
        let protectedControls = controls.allSatisfy { control in
            !panel.isBackground(atWindowPoint: control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil))
        }
        let protectedCards = cards.filter { !$0.visibleRect.isEmpty }.allSatisfy { card in
            !panel.isBackground(atWindowPoint: card.convert(NSPoint(x: card.visibleRect.midX, y: card.visibleRect.midY), to: nil))
        }
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: backgroundPoint,
                                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            completion(["success": false, "reason": "Mouse event unavailable"]); return
        }
        NSApplication.shared.postEvent(event, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let restored = WindowCatalog.focusedID(pid: expected.pid) == expected.id
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid
            let closed = !self.isVisible
            completion(["success": closed && restored && classified && protectedControls && protectedCards,
                        "overviewDismissed": closed, "exactOriginalWindowRestored": restored,
                        "selectionChangedBeforeClick": changedSelection, "backgroundRecognized": classified,
                        "controlsProtected": protectedControls, "cardsProtected": protectedCards])
        }
    }

    private func safeMargins() -> Bool {
        guard let scroll else { return false }
        return safeArea.contains(scroll.frame) && cards.allSatisfy {
            $0.frame.minX >= 15 && $0.frame.maxX <= scroll.contentSize.width - 15
        } && scroll.contentView.bounds.minX == 0
    }

    private func centeredGrid() -> Bool {
        guard let document = scroll?.documentView, !cards.isEmpty else { return cards.isEmpty }
        for start in stride(from: 0, to: cards.count, by: metrics.columns) {
            let row = cards[start..<min(cards.count, start + metrics.columns)]
            guard let first = row.first, let last = row.last,
                  abs((first.frame.minX + last.frame.maxX) / 2 - document.bounds.midX) < 0.5 else { return false }
        }
        return abs((cards.first!.frame.minY + cards.last!.frame.maxY) / 2 - document.bounds.midY) < 0.5
    }

    func report() -> [String: Any] {
        ["otherSpaceWindowCount": otherCards.count, "otherSpaceGroupCount": otherGroups.count,
         "otherSpaceIDs": otherGroups.map(\.id), "otherSpaceKeys": otherCards.map { $0.item.key },
         "otherStripSafeMargins": otherScroll.map { safeArea.contains($0.frame) } ?? true,
         "visible": isVisible, "applications": windows.map(\.app), "minimizedKeys": windows.filter { $0.isMinimized }.map(\.key), "scope": scope.rawValue, "applicationPID": applicationPID ?? -1,
         "safeMargins": safeMargins(), "centeredGrid": centeredGrid(),
         "activeWindowKey": originalWindow?.key ?? "",
         "yellowBorderCount": cards.filter { $0.selected && !$0.isCurrentWindow && !$0.quittingAppPreview }.count, "activeBorderCount": cards.filter { $0.isCurrentWindow }.count, "windowCount": windows.count, "keys": windows.map(\.key),
         "columns": metrics.columns, "cardWidth": metrics.cardWidth, "cardHeight": metrics.cardHeight,
         "backgroundOpacity": backgroundOpacity, "preferredWidth": preferredWidth,
         "sizeMode": manualSize ? "manual" : "automatic", "sizeDisplayKey": sizeDisplayKey ?? "unavailable", "sizeDisplayName": sizeDisplayName,
         "fullCardPreviews": cards.allSatisfy { $0.imageView.frame == $0.bounds },
         "previewsAllowed": CGPreflightScreenCaptureAccess(),
         "previewCount": cards.filter { $0.imageView.imageScaling == .scaleProportionallyUpOrDown }.count]
    }
}

func overviewTests() {
    overviewSizingTests()
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    check(WindowCatalog.acceptsLayer(-1, role: kAXWindowRole, subrole: kAXStandardWindowSubrole), "visible Claude standard window accepted below normal level")
    check(WindowCatalog.acceptsLayer(3, role: kAXWindowRole, subrole: kAXStandardWindowSubrole), "standard floating document window accepted")
    check(WindowCatalog.acceptsLayer(0, role: nil, subrole: nil), "ordinary windows do not require AX metadata")
    check(!WindowCatalog.acceptsLayer(25, role: kAXMenuBarRole, subrole: nil), "menu bar excluded")
    check(!WindowCatalog.acceptsLayer(-1, role: nil, subrole: nil), "unconfirmed nonstandard surfaces excluded")
    check(!WindowCatalog.acceptsLayer(3, role: kAXWindowRole, subrole: kAXFloatingWindowSubrole), "floating utility surface excluded")
    print("PASS: ordinary/custom-level standard windows included; menu and utility surfaces excluded")
    check(WindowCatalog.acceptsOffSpaceFallback(layer: 0, title: "Browser document", hasSpace: true, hasAXElement: false), "off-Space window survives missing AX metadata")
    check(WindowCatalog.acceptsOffSpaceFallback(layer: -1, title: "Claude", hasSpace: true, hasAXElement: false), "off-Space Claude below normal layer")
    check(!WindowCatalog.acceptsOffSpaceFallback(layer: 0, title: "", hasSpace: true, hasAXElement: false), "unnamed Chrome accessory excluded")
    check(!WindowCatalog.acceptsOffSpaceFallback(layer: 0, title: "Stale surface", hasSpace: false, hasAXElement: false), "unassigned surface excluded")
    check(!WindowCatalog.acceptsOffSpaceFallback(layer: 3, title: "Utility", hasSpace: true, hasAXElement: false), "unconfirmed floating utility excluded")
    check(!WindowCatalog.acceptsOffSpaceFallback(layer: 0, title: "AX utility", hasSpace: true, hasAXElement: true), "known AX utility cannot use fallback")
    print("PASS: off-Space fallback includes documents and excludes accessory/stale/utility surfaces")
    let pid = ProcessInfo.processInfo.processIdentifier
    func window(_ id: UInt32, _ app: String, _ title: String, _ process: Int32? = nil) -> OverviewWindow {
        OverviewWindow(id: id, pid: process ?? pid, app: app, title: title,
                       bundleID: app == "IDE" ? "com.jetbrains.intellij" : app, frame: .zero)
    }
    let a = window(10, "Alpha", "Window 10"), b = window(20, "Alpha", "window 2"), c = window(30, "Beta", "A")
    check(AlphabeticalWindowOrder.sorted([c, a, b]).map(\.id) == [20, 10, 30], "sort app then natural window title")
    check(AlphabeticalWindowOrder.sorted([a, c, b]).map(\.id) == [20, 10, 30], "z-order cannot affect alphabetical order")
    let groups = otherSpaceGroups(catalog: [c, a, b], state: SpaceState(display: "test", ids: [1, 2, 3], index: 0)) { id, space in
        (id == a.id && [UInt64(1), 2].contains(space)) || (id == b.id && [UInt64(2), 3].contains(space)) || (id == c.id && space == 3)
    }
    check(groups.map(\.id) == [2, 3], "other Space groups follow desktop order")
    check(groups.flatMap { $0.windows }.map(\.id) == [b.id, c.id], "current and all-Spaces windows cannot duplicate into strip")
    check(groups.map(\.number) == [2, 3], "Space labels retain system desktop positions")
    check(otherSpaceGroups(catalog: [a], state: SpaceState(display: "test", ids: [1], index: 0)) { _, _ in true }.isEmpty,
          "single Space needs no bottom strip")
    print("PASS: other Space grouping/order, current-Space exclusion, no duplicates")
    let first = window(1000, "IDE", "One – old.go"), second = window(1001, "IDE", "Two – file.go")
    let newFirst = window(2000, "IDE", "One – changed.go", pid + 100)
    let newSecond = window(2001, "IDE", "Two – file.go", pid + 100)
    check(AlphabeticalWindowOrder.sorted([second, first]).map(\.title) == [first.title, second.title], "project alphabetical order")
    check(AlphabeticalWindowOrder.sorted([newSecond, newFirst]).map(\.id) == [2000, 2001], "restart and changed file preserve project order")
    let identical = window(11, "Alpha", "Window 10")
    check(AlphabeticalWindowOrder.sorted([identical, a]).map(\.id) == [10, 11], "identical titles have deterministic tie order")
    print("PASS: alphabetical app/window sorting, natural numbers, focus independence, project restart/file changes")
    let grid = GridMetrics(width: 1440)
    check(grid.rect(index: 0).size == grid.rect(index: 17).size, "all cards same size")
    check(grid.rect(index: 0) == GridMetrics(width: 1440).rect(index: 0), "grid independent of window count")
    check(GridMetrics(width: 320).columns == 1, "small display column clamp")
    let small = GridMetrics(width: 1440, preferredWidth: 220)
    let large = GridMetrics(width: 1440, preferredWidth: 520)
    check(small.columns > large.columns, "size control changes density")
    for width: CGFloat in [320, 768, 1440, 2560] {
        for size: CGFloat in [220, 288, 520, 999] {
            let layout = GridMetrics(width: width, preferredWidth: size)
            check(layout.gridWidth <= max(120, width - 32), "grid fits available display width")
            check(layout.rect(index: 19).size == layout.rect(index: 0).size, "size control preserves equal cards")
            check(layout.rect(index: layout.columns).minY >= layout.rect(index: 0).maxY, "rows never overlap")
        }
    }
    let centeredRows = [CGRect(x: 0, y: 0, width: 200, height: 150),
                        CGRect(x: 220, y: 0, width: 200, height: 150),
                        CGRect(x: 440, y: 0, width: 200, height: 150),
                        CGRect(x: 660, y: 0, width: 200, height: 150),
                        CGRect(x: 220, y: 170, width: 200, height: 150),
                        CGRect(x: 440, y: 170, width: 200, height: 150)]
    check(verticalSelection(from: 4, step: -1, frames: centeredRows) == 1, "centered lower-left goes straight up")
    check(verticalSelection(from: 5, step: -1, frames: centeredRows) == 2, "centered lower-right goes straight up")
    check(verticalSelection(from: 1, step: 1, frames: centeredRows) == 4, "upper center-left goes straight down")
    check(verticalSelection(from: 2, step: 1, frames: centeredRows) == 5, "upper center-right goes straight down")
    check(verticalSelection(from: 0, step: 1, frames: centeredRows) == 4, "upper edge chooses nearest lower card")
    check(verticalSelection(from: 3, step: 1, frames: centeredRows) == 5, "opposite edge chooses nearest lower card")
    check(verticalSelection(from: 2, step: -1, frames: centeredRows) == 2, "top edge retains selection")
    check(verticalSelection(from: 4, step: 1, frames: centeredRows) == 4, "bottom edge retains selection")
    let fullRows = centeredRows.prefix(4) + [CGRect(x: 0, y: 170, width: 200, height: 150),
                                          CGRect(x: 220, y: 170, width: 200, height: 150),
                                          CGRect(x: 440, y: 170, width: 200, height: 150),
                                          CGRect(x: 660, y: 170, width: 200, height: 150)]
    check(verticalSelection(from: 6, step: -1, frames: Array(fullRows)) == 2, "full rows preserve vertical column")
    let oddRow = Array(centeredRows.prefix(4)) + [CGRect(x: 330, y: 170, width: 200, height: 150)]
    check(verticalSelection(from: 4, step: -1, frames: oddRow) == 1, "equal-distance tie is stable")
    check(verticalSelection(from: 0, step: -1, frames: []) == 0, "empty grid navigation is safe")
    print("PASS: spatial vertical navigation in centered/full rows, nearest edge, stable ties")
    let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    for visible in [screen.insetBy(dx: 0, dy: 24),
                    CGRect(x: -1830, y: 100, width: 1830, height: 1056),
                    CGRect(x: -1920, y: 190, width: 1920, height: 966),
                    CGRect(x: -1920, y: 100, width: 1830, height: 1056)] {
        let safe = overviewSafeArea(screen: screen, visible: visible)
        let global = CGRect(x: safe.minX + screen.minX, y: screen.maxY - safe.maxY,
                            width: safe.width, height: safe.height)
        check(visible.insetBy(dx: 23, dy: 23).contains(global), "menu/Dock margins on offset display")
    }
    print("PASS: fixed-size grid, centered layout and safe margins")
}
