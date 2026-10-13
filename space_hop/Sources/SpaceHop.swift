import AppKit
import ApplicationServices
import ServiceManagement
import Darwin

// Synthetic Dock gesture and Spaces bookkeeping adapted from MIT-licensed
// jurplel/InstantSpaceSwitcher and mmathys/noswoosh. See bundled licenses.
// This build deliberately targets macOS 13–15; newer versions need validation.

enum Direction: Int { case left = -1, right = 1 }

struct SpaceState {
    let display: String
    let ids: [UInt64]
    let index: Int
    var id: UInt64 { ids[index] }
    func destination(_ direction: Direction) -> Int? {
        let next = index + direction.rawValue
        return ids.indices.contains(next) ? next : nil
    }
}

final class SpaceReader {
    typealias Connection = @convention(c) () -> UInt32
    typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    typealias ActiveSpace = @convention(c) (UInt32) -> UInt64
    typealias WindowSpaces = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let handle: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let copySpaces: CopySpaces?
    private let activeSpace: ActiveSpace?
    private let windowSpaces: WindowSpaces?

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        handle = library
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let library, let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connection = symbol("SLSMainConnectionID", Connection.self)
        copySpaces = symbol("SLSCopyManagedDisplaySpaces", CopySpaces.self)
        activeSpace = symbol("SLSGetActiveSpace", ActiveSpace.self)
        windowSpaces = symbol("SLSCopySpacesForWindows", WindowSpaces.self)
    }

    deinit { if let handle { dlclose(handle) } }

    func spaces(windowID: CGWindowID) -> [UInt64]? {
        guard let connection, let windowSpaces else { return nil }
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let spaces = windowSpaces(connection(), 7, windows)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.map { $0.uint64Value }
    }

    func contains(windowID: CGWindowID, spaceID: UInt64) -> Bool? {
        spaces(windowID: windowID)?.contains(spaceID)
    }

    func read() -> SpaceState? {
        guard let connection, let copySpaces, let activeSpace else { return nil }
        let cid = connection()
        guard let array = copySpaces(cid)?.takeRetainedValue(),
              let displays = array as? [[String: Any]] else { return nil }
        func parse(_ display: [String: Any], current: UInt64) -> SpaceState? {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
            let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard let index = ids.firstIndex(of: current) else { return nil }
            return SpaceState(display: display["Display Identifier"] as? String ?? "Main",
                              ids: ids, index: index)
        }
        // Dock gestures land on the display under the pointer, including
        // fullscreen Spaces. Use that display's own current space.
        if displays.count > 1, let point = CGEvent(source: nil)?.location {
            var displayID: CGDirectDisplayID = 0
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success,
               count > 0, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                let name = CFUUIDCreateString(nil, uuid) as String
                if let display = displays.first(where: { $0["Display Identifier"] as? String == name }),
                   let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber {
                    return parse(display, current: current.uint64Value)
                }
            }
            // Unknown target monitor: leave native shortcuts available.
            return nil
        }
        let current = activeSpace(cid)
        return displays.compactMap { parse($0, current: current) }.first
    }
}

enum DockGesture {
    static let syntheticTag: Int64 = 0x5350414345484F50
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticTag
    }
    static func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }
    static func events(_ direction: Direction) -> [CGEvent]? {
        let sign = Double(direction.rawValue)
        var result: [CGEvent] = []
        for phase: Int64 in [1, 2, 4] {
            guard let event = CGEvent(source: nil) else { return nil }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            event.setIntegerValueField(field(55), value: 30)   // DockControl
            event.setIntegerValueField(field(110), value: 23)  // Dock swipe HID
            event.setIntegerValueField(field(132), value: phase)
            event.setIntegerValueField(field(123), value: 1)   // horizontal
            // Nonzero normal float preserves the sign on Apple Silicon.
            event.setDoubleValueField(field(124), value: sign * 0.0001)
            event.setDoubleValueField(field(129), value: sign * 2000)
            event.setDoubleValueField(field(130), value: sign * 2000)
            result.append(event)
        }
        return result
    }
}

func shortcutDirection(key: Int64, flags: CGEventFlags) -> Direction? {
    let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    guard flags.intersection(relevant) == .maskControl else { return nil }
    if key == 123 { return .left }
    if key == 124 { return .right }
    return nil
}

final class SpaceSwitcher {
    let reader = SpaceReader()
    var onStatus: ((String) -> Void)?
    var onFailure: (() -> Void)?
    var onOverview: ((OverviewScope) -> Void)?
    var onGesture: ((CGEvent, CGEventTapProxy) -> Bool)?
    var onGestureReset: (() -> Void)?
    private(set) var enabled = true
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeys = Set<Int64>()
    private var nativeDragKeys = Set<Int64>()
    private let leftMouseButtonDown: () -> Bool
    private var pending = false
    private var lastSwitch = 0.0
    private(set) var handledHotkeys = 0
    private(set) var verifiedTransitions = 0
    var ready: Bool { tap != nil && AXIsProcessTrusted() }
    var supported: Bool { (13...15).contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }

    init(leftMouseButtonDown: @escaping () -> Bool = {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }) {
        self.leftMouseButtonDown = leftMouseButtonDown
    }

    func start() -> Bool {
        guard supported, AXIsProcessTrusted() else { return false }
        if let tap, CFMachPortIsValid(tap) { return true }
        stop()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                 | (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<SpaceSwitcher>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(type, event, proxy: proxy)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let newSource = CFMachPortCreateRunLoopSource(nil, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            return false
        }
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowedKeys.removeAll()
        nativeDragKeys.removeAll()
        onGestureReset?()
    }

    func setEnabled(_ value: Bool) { enabled = value }

    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedKeys.removeAll()
            nativeDragKeys.removeAll()
            onGestureReset?()
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if DockGesture.isSynthetic(event) { return Unmanaged.passUnretained(event) }
        if (type.rawValue == 29 || type.rawValue == 30), enabled {
            return onGesture?(event, proxy) == true ? nil : Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // A shortcut started while holding a window belongs entirely to macOS,
        // including repeats after the mouse is released and its matching key-up.
        if type == .keyUp, nativeDragKeys.remove(key) != nil { return Unmanaged.passUnretained(event) }
        if type == .keyUp, swallowedKeys.remove(key) != nil { return nil }
        if type == .keyDown, nativeDragKeys.contains(key) { return Unmanaged.passUnretained(event) }
        if type == .keyDown, enabled, (key == 126 || key == 125),
           event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == .maskControl {
            swallowedKeys.insert(key)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onOverview?(key == 126 ? .all : .application) }
            }
            return nil
        }
        guard type == .keyDown, enabled,
              let direction = shortcutDirection(key: key, flags: event.flags) else { return Unmanaged.passUnretained(event) }
        if leftMouseButtonDown() {
            // Never pass an unmatched repeat/key-up of a shortcut we already
            // consumed. Starting a new press during a drag uses native handling.
            if swallowedKeys.contains(key) { return nil }
            nativeDragKeys.insert(key)
            return Unmanaged.passUnretained(event)
        }
        guard let state = reader.read() else { return Unmanaged.passUnretained(event) }
        swallowedKeys.insert(key)
        handledHotkeys += 1
        // At the edge, consume the shortcut to avoid native rubber-band motion.
        guard state.destination(direction) != nil else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending, now - lastSwitch > 0.12 else { return nil }
        pending = true
        DispatchQueue.main.async { [weak self] in self?.perform(direction) }
        return nil
    }

    func move(_ direction: Direction) {
        guard enabled, ready, !pending else { return }
        pending = true
        perform(direction)
    }

    // Traverse adjacent Spaces using the same verified instant Dock gesture.
    // Never focus the requested window until the destination is confirmed.
    func move(to target: UInt64, display: String, completion: @escaping (Bool) -> Void) {
        guard enabled, ready, !pending, let state = reader.read(), state.display == display,
              state.ids.contains(target) else { completion(false); return }
        pending = true
        navigate(to: target, display: display, remaining: state.ids.count, completion: completion)
    }

    private func navigate(to target: UInt64, display: String, remaining: Int, completion: @escaping (Bool) -> Void) {
        guard enabled, AXIsProcessTrusted(), let state = reader.read(), state.display == display,
              let index = state.ids.firstIndex(of: target) else { pending = false; completion(false); return }
        if state.id == target { pending = false; completion(true); return }
        guard remaining > 0, let events = DockGesture.events(index < state.index ? .left : .right) else {
            pending = false; completion(false); return
        }
        let next = state.ids[state.index + (index < state.index ? -1 : 1)]
        lastSwitch = ProcessInfo.processInfo.systemUptime
        for event in events { event.post(tap: .cgSessionEventTap) }
        awaitNavigationStep(next: next, target: target, display: display, remaining: remaining - 1,
                            attempt: 0, completion: completion)
    }

    private func awaitNavigationStep(next: UInt64, target: UInt64, display: String, remaining: Int,
                                     attempt: Int, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { completion(false); return }
            guard let state = self.reader.read(), state.display == display else {
                self.pending = false; completion(false); return
            }
            if state.id == next {
                self.verifiedTransitions += 1
                self.navigate(to: target, display: display, remaining: remaining, completion: completion)
            } else if attempt < 9 {
                self.awaitNavigationStep(next: next, target: target, display: display, remaining: remaining,
                                         attempt: attempt + 1, completion: completion)
            } else { self.pending = false; completion(false) }
        }
    }

    private func perform(_ direction: Direction) {
        guard enabled, AXIsProcessTrusted(), let before = reader.read(),
              let target = before.destination(direction), let events = DockGesture.events(direction) else {
            pending = false
            return
        }
        let targetID = before.ids[target]
        lastSwitch = ProcessInfo.processInfo.systemUptime
        for event in events { event.post(tap: .cgSessionEventTap) }
        verify(before: before, targetID: targetID, attempt: 0)
    }

    private func verify(before: SpaceState, targetID: UInt64, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            if let after = self.reader.read(), after.display == before.display, after.id == targetID {
                self.pending = false
                self.verifiedTransitions += 1
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - self.lastSwitch) * 1000)
                self.onStatus?("Space \(after.index + 1) из \(after.ids.count) · \(elapsed) мс")
                NSLog("SpaceHop: verified space %llu -> %llu in %d ms", before.id, after.id, elapsed)
            } else if attempt < 9 {
                self.verify(before: before, targetID: targetID, attempt: attempt + 1)
            } else {
                self.pending = false
                self.enabled = false
                self.onStatus?("Не удалось подтвердить переход — приостановлено")
                self.onFailure?()
                NSLog("SpaceHop: unconfirmed switch; paused to restore native shortcuts")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = SpaceSwitcher()
    private let overview = OverviewController()
    private let gestures = VerticalGestureRouter()
    private let horizontalGestures = HorizontalGestureRouter()
    private lazy var gestureSettings = GestureSettingsController(gestures: horizontalGestures)
    private var settingsShown = false
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Запуск…", action: nil, keyEquivalent: "")
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var swipeItem: NSMenuItem!
    private var timer: Timer?
    private var lastStatus = ""
    private var welcome: NSWindow?
    private var verificationStarted = false
    private var overviewVerificationStarted = false
    private var previewsRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.spacehop.app")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: "SpaceHop")
        statusItem.button?.toolTip = "SpaceHop · Ctrl + ←/→"
        let menu = NSMenu()
        let title = NSMenuItem(title: "SpaceHop · Spaces и окна", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(statusLine)
        menu.addItem(.separator())
        add("Обзор окон · Ctrl + ↑", #selector(showOverview), to: menu)
        add("Окна приложения · Ctrl + ↓", #selector(showApplicationOverview), to: menu)
        swipeItem = add("Обзор свайпами", #selector(toggleSwipe), to: menu)
        add("Настройки жестов трекпада…", #selector(showGestureSettings), to: menu)
        add("Разрешить превью окон…", #selector(allowPreviews), to: menu)
        menu.addItem(.separator())
        pauseItem = add("Приостановить", #selector(togglePause), to: menu)
        add("Перейти влево", #selector(left), to: menu)
        add("Перейти вправо", #selector(right), to: menu)
        menu.addItem(.separator())
        add("Разрешить Универсальный доступ…", #selector(openAccessibility), to: menu)
        loginItem = add("Запускать при входе", #selector(toggleLogin), to: menu)
        add("Инструкция…", #selector(showHelp), to: menu)
        menu.addItem(.separator())
        add("Выйти из SpaceHop", #selector(quit), to: menu)
        statusItem.menu = menu
        switcher.onStatus = { [weak self] text in self?.lastStatus = text; self?.refresh() }
        switcher.onFailure = { [weak self] in self?.horizontalGestures.reset(); self?.gestures.reset(); self?.refresh() }
        switcher.onOverview = { [weak self] scope in self?.overview.toggle(scope: scope) }
        overview.onNavigate = { [weak self] window, space, display in
            self?.switcher.move(to: space, display: display) { [weak self] arrived in
                guard arrived else { self?.lastStatus = "Не удалось перейти к выбранному окну"; NSSound.beep(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    let focused = WindowCatalog.focus(window)
                    self?.overview.onFocus?(focused)
                    if !focused { NSSound.beep() }
                }
            }
        }
        switcher.onGestureReset = { [weak self] in self?.horizontalGestures.reset(); self?.gestures.reset() }
        switcher.onGesture = { [weak self] event, proxy in
            guard let self else { return false }
            if self.horizontalGestures.handle(event, proxy: proxy) { return true }
            return self.gestures.handle(event, proxy: proxy)
        }
        horizontalGestures.canBegin = { [weak self] in
            guard let self else { return false }
            return self.switcher.enabled && self.switcher.ready && self.switcher.reader.read() != nil
        }
        horizontalGestures.onSwitch = { [weak self] direction in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overview.dismiss(restore: false)
                self.switcher.move(direction)
            }
        }
        gestureSettings.onChange = { [weak self] in self?.refresh() }
        gestures.onUp = { [weak self] in self?.overview.show() }
        gestures.onDown = { [weak self] in self?.overview.dismiss() }
        gestures.onApplication = { [weak self] in self?.overview.show(scope: .application) }
        gestures.overviewVisible = { [weak self] in self?.overview.isVisible == true }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        if !AXIsProcessTrusted() { showWelcome() }
    }

    @discardableResult
    private func add(_ title: String, _ selector: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func refresh() {
        if !switcher.supported { statusLine.title = "Эта сборка поддерживает macOS 13–15" }
        else if !AXIsProcessTrusted() {
            switcher.stop()
            statusLine.title = "Нужен доступ: Универсальный доступ"
        } else if !switcher.start() { statusLine.title = "Не удалось подключить горячие клавиши" }
        else if !switcher.enabled { statusLine.title = "Приостановлено · обычное переключение" }
        else { statusLine.title = lastStatus.isEmpty ? "Работает · Ctrl + ←/→" : lastStatus }
        pauseItem.title = switcher.enabled ? "Приостановить" : "Возобновить"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        swipeItem.state = gestures.enabled ? .on : .off
        statusItem.button?.appearsDisabled = !switcher.enabled || !switcher.ready
        if switcher.ready { welcome?.close(); welcome = nil }
        if switcher.ready, CGPreflightScreenCaptureAccess(), !settingsShown, CommandLine.arguments.contains("--show-gesture-settings") {
            settingsShown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showGestureSettings() }
        }
        if switcher.ready, !verificationStarted, CommandLine.arguments.contains("--verify-hotkeys") {
            verificationStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.verifyHotkeys() }
        }
        if switcher.ready, !previewsRequested, CommandLine.arguments.contains("--request-previews"),
           !CGPreflightScreenCaptureAccess() {
            previewsRequested = true
            overview.requestPreviews()
        }
        if switcher.ready, CGPreflightScreenCaptureAccess(), !overviewVerificationStarted,
           (CommandLine.arguments.contains("--verify-overview") || CommandLine.arguments.contains("--verify-modes") || CommandLine.arguments.contains("--verify-close-in-place") || CommandLine.arguments.contains("--verify-minimize-fixture") || CommandLine.arguments.contains("--verify-previews") || CommandLine.arguments.contains("--verify-other-spaces")) {
            overviewVerificationStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if CommandLine.arguments.contains("--verify-previews") || CommandLine.arguments.contains("--verify-other-spaces") { self?.verifyPreviews() }
                else if CommandLine.arguments.contains("--verify-minimize-fixture") { self?.verifyMinimizeFixture() }
                else if CommandLine.arguments.contains("--verify-close-in-place") { self?.verifyCloseInPlace() }
                else if CommandLine.arguments.contains("--verify-modes") { self?.verifyModes() }
                else { self?.verifyOverview() }
            }
        }
    }

    private func verifyPreviews() {
        overview.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let report = self.overview.previewReport()
            self.overview.dismiss()
            self.writeVerification(report)
        }
    }

    private func verifyMinimizeFixture() {
        let original = NSWorkspace.shared.frontmostApplication
        let space = switcher.reader.read()?.id
        let fixtures = WindowCatalog.current().filter { $0.bundleID == "local.spacehop.close-fixture" }
        guard let target = fixtures.first(where: { $0.title == "Disposable window" }),
              let other = fixtures.first(where: { $0.title == "Unsaved test window" }) else {
            writeVerification(["success": false, "reason": "Missing disposable fixture"]); return
        }
        _ = WindowCatalog.focus(other)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.overview.show(scope: .application)
            let keys = self.overview.windows.map(\.key), panel = self.overview.panel
            guard let index = self.overview.windows.firstIndex(where: { $0.key == target.key }) else {
                self.writeVerification(["success": false, "reason": "Fixture missing from current Space"]); return
            }
            self.overview.toggleMinimized(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let minimized = WindowCatalog.minimized(target) == true
                let samePanel = self.overview.isVisible && self.overview.panel === panel && self.overview.windows.map(\.key) == keys
                let first = self.overview.report()
                self.overview.dismiss(restore: false)
                self.overview.show(scope: .application)
                let reopen = self.overview.report()
                let recalled = self.overview.windows.first(where: { $0.key == target.key })?.isMinimized == true
                let currentSpace = self.switcher.reader.contains(windowID: target.id, spaceID: space ?? 0)
                guard let index = self.overview.windows.firstIndex(where: { $0.key == target.key }) else {
                    self.overview.dismiss(restore: false)
                    _ = WindowCatalog.setMinimized(false, window: target)
                    NSRunningApplication(processIdentifier: target.pid)?.terminate()
                    if original?.processIdentifier != target.pid { original?.activate(options: [.activateIgnoringOtherApps]) }
                    self.writeVerification(["success": false, "minimized": minimized, "samePanel": samePanel,
                                            "reason": "Minimized window missing after reopen", "spaceMembership": currentSpace ?? false]); return
                }
                let restoredPanel = self.overview.panel
                let card = restoredPanel?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?
                    .documentView?.subviews.compactMap { $0 as? WindowCard }.first { $0.item.key == target.key }
                card?.toggleMinimized?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let restored = WindowCatalog.minimized(target) == false && self.overview.isVisible
                        && self.overview.panel === restoredPanel && self.overview.windows.map(\.key) == keys
                    self.overview.toggleMinimized(index)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.overview.choose(index)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let chosen = !self.overview.isVisible && WindowCatalog.minimized(target) == false
                                && WindowCatalog.focusedID(pid: target.pid) == target.id
                            self.overview.dismiss(restore: false)
                            NSRunningApplication(processIdentifier: target.pid)?.terminate()
                            if original?.processIdentifier != target.pid { original?.activate(options: [.activateIgnoringOtherApps]) }
                            self.writeVerification(["success": minimized && samePanel && recalled && restored && chosen
                                && self.switcher.reader.read()?.id == space,
                                "minimizedInPlace": minimized && samePanel, "minimizedReappears": recalled,
                                "restoreButtonKeepsPanel": restored, "choosingMinimizedRestoresExactWindow": chosen,
                                "spaceMembership": currentSpace ?? false, "spaceUnchanged": self.switcher.reader.read()?.id == space,
                                "afterMinimize": first, "afterReopen": reopen])
                        }
                    }
                }
            }
        }
    }

    private func verifyCloseInPlace() {
        // Every destructive action is limited to our disposable fixture app.
        let fixtures = WindowCatalog.current().filter { $0.bundleID == "local.spacehop.close-fixture" }
        guard let disposable = fixtures.first(where: { $0.title == "Disposable window" }),
              let second = fixtures.first(where: { $0.title == "Second disposable window" }),
              let protected = fixtures.first(where: { $0.title == "Unsaved test window" }) else {
            writeVerification(["success": false, "reason": "Missing disposable fixture"]); return
        }
        let original = NSWorkspace.shared.frontmostApplication
        let space = switcher.reader.read()?.id
        _ = WindowCatalog.focus(protected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.overview.show(scope: .application)
            let panel = self.overview.panel
            let initial = self.overview.report()
            guard let index = self.overview.windows.firstIndex(where: { $0.key == disposable.key }) else {
                self.overview.dismiss(); self.writeVerification(["success": false, "reason": "Fixture absent from overview"]); return
            }
            self.overview.closeWindow(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let firstStayed = self.overview.isVisible && self.overview.panel === panel
                let exactClosed = !WindowCatalog.liveKeys().contains(disposable.key)
                    && WindowCatalog.liveKeys().contains(protected.key)
                let first = self.overview.report()
                guard let index = self.overview.windows.firstIndex(where: { $0.key == second.key }) else {
                    self.overview.dismiss(); self.writeVerification(["success": false, "first": first]); return
                }
                self.overview.closeWindow(index)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    let secondStayed = self.overview.isVisible && self.overview.panel === panel
                        && self.overview.windows.map(\.key) == [protected.key]
                    let second = self.overview.report()
                    guard let card = self.overview.panel?.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first?.documentView?.subviews.compactMap({ $0 as? WindowCard }).first,
                          card.item.key == protected.key else {
                        self.overview.dismiss(); self.writeVerification(["success": false, "second": second]); return
                    }
                    // Invoke the rebound card action to catch stale indices.
                    card.closeWindow?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        let handoff = !self.overview.isVisible && WindowCatalog.liveKeys().contains(protected.key)
                            && NSWorkspace.shared.frontmostApplication?.processIdentifier == protected.pid
                        let fixturePath = CommandLine.arguments.first(where: { $0.hasPrefix("--fixture-report=") }).map { String($0.dropFirst("--fixture-report=".count)) }
                        let fixture = fixturePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        let prompted = fixture["promptShown"] as? Bool == true
                        let green = first["activeWindowKey"] as? String == protected.key
                            && second["activeBorderCount"] as? Int == 1
                        self.overview.dismiss(restore: false)
                        NSRunningApplication(processIdentifier: protected.pid)?.terminate()
                        if original?.processIdentifier != protected.pid { original?.activate(options: [.activateIgnoringOtherApps]) }
                        self.writeVerification(["success": firstStayed && secondStayed && exactClosed && handoff && prompted && green
                            && self.switcher.reader.read()?.id == space,
                            "samePanelAfterBothCloses": firstStayed && secondStayed, "exactWindowClosed": exactClosed,
                            "activeGreenRetained": green, "saveDialogHandoff": handoff, "nativeSaveDialogShown": prompted,
                            "reboundCloseActionWorks": prompted, "spaceUnchanged": self.switcher.reader.read()?.id == space,
                            "initial": initial, "afterFirstClose": first, "afterSecondClose": second])
                    }
                }
            }
        }
    }

    private func verifyModes() {
        let original = NSWorkspace.shared.frontmostApplication
        let initialSpace = switcher.reader.read()?.id
        let candidates = WindowCatalog.current().filter {
            guard let initialSpace else { return false }
            return switcher.reader.contains(windowID: $0.id, spaceID: initialSpace) == true
        }
        guard let target = candidates.first(where: { $0.pid == original?.processIdentifier }) ?? candidates.first else {
            writeVerification(["success": false, "reason": "No current-Space windows"]); return
        }
        _ = WindowCatalog.focus(target)
        func hotkey(_ key: CGKeyCode, control: Bool = true) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
                event.flags = control ? [.maskControl, .maskSecondaryFn, .maskNumericPad] : []
                event.post(tap: .cghidEventTap)
            }
        }
        var samples: [[String: Any]] = []
        var appKeys: [String] = []
        var globalKeys: [String] = []
        var success = true
        let sequence: [CGKeyCode] = [125, 126, 125, 126, 125]
        func step(_ index: Int) {
            if index == sequence.count {
                let controls = self.overview.verifyControls()
                hotkey(53, control: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let escaped = !self.overview.isVisible
                    let restored = WindowCatalog.focusedID(pid: target.pid) == target.id
                    self.overview.dismiss(restore: false)
                    original?.activate(options: [.activateIgnoringOtherApps])
                    self.writeVerification(["success": success && escaped && restored && controls["success"] as? Bool == true,
                        "samples": samples, "controls": controls, "escapeDismissed": escaped,
                        "originalWindowRetained": restored,
                        "spaceUnchanged": self.switcher.reader.read()?.id == initialSpace])
                }
                return
            }
            let previous = self.overview.panel
            hotkey(sequence[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let report = self.overview.report()
                let keys = self.overview.windows.map(\.key)
                let isApp = sequence[index] == 125
                let filtered = !isApp || self.overview.windows.allSatisfy { $0.pid == target.pid }
                let scopeMatched = self.overview.scope == (isApp ? .application : .all)
                let oldClosed = previous?.isVisible != true
                let onlyOne = NSApp.windows.filter { $0 is OverviewPanel && $0.isVisible }.count == 1
                let sameSpace = self.switcher.reader.read()?.id == initialSpace
                if index == 0 { appKeys = keys }
                if index == 1 { globalKeys = keys }
                let stable = keys == (isApp ? appKeys : globalKeys)
                let relativeOrder = !isApp || index == 0 || keys == globalKeys.filter { appKeys.contains($0) }
                success = success && self.overview.isVisible && filtered && scopeMatched && oldClosed && onlyOne
                    && sameSpace && stable && relativeOrder && report["safeMargins"] as? Bool == true
                var sample = report
                sample["onlyTargetApplication"] = filtered; sample["onePanel"] = onlyOne
                sample["previousPanelClosed"] = oldClosed; sample["stableOrder"] = stable
                sample["relativeGlobalOrder"] = relativeOrder
                samples.append(sample)
                step(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step(0) }
    }

    private func verifyOverview() {
        let original = NSWorkspace.shared.frontmostApplication
        let initialSpace = switcher.reader.read()?.id
        func openHotkey() {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 126, keyDown: down) else { return }
                event.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
                event.post(tap: .cghidEventTap)
            }
        }
        openHotkey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let first = self.overview.report()
            let controls = self.overview.verifyControls()
            let keys = self.overview.windows.map(\.key)
            guard self.overview.isVisible, let target = self.overview.windows.first else {
                self.writeVerification(["success": false, "overview": first]); return
            }
            self.overview.choose(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                let focusMatched = WindowCatalog.focusedID(pid: target.pid) == target.id
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
                openHotkey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    let second = self.overview.report()
                    let stable = self.overview.windows.map(\.key) == keys
                    let sameSpace = self.switcher.reader.read()?.id == initialSpace
                    var report: [String: Any] = ["success": stable && focusMatched && sameSpace && controls["success"] as? Bool == true,
                                            "firstOverview": first, "secondOverview": second, "controls": controls,
                                            "stableOrderAfterFocus": stable, "exactWindowFocused": focusMatched,
                                            "spaceUnchanged": sameSpace,
                                            "onlyCurrentSpace": self.overview.windows.allSatisfy {
                                                guard let initialSpace else { return false }
                                                return self.switcher.reader.contains(windowID: $0.id, spaceID: initialSpace) == true
                                            }]
                    self.overview.verifyBackgroundClick { background in
                        report["backgroundClick"] = background
                        report["success"] = report["success"] as? Bool == true && background["success"] as? Bool == true
                        self.overview.dismiss(restore: false)
                        original?.activate(options: [.activateIgnoringOtherApps])
                        if CommandLine.arguments.contains("--verify-close-fixture") {
                            self.verifyFixtureClose { closeReport in
                                report["closeFixture"] = closeReport
                                report["success"] = report["success"] as? Bool == true && closeReport["success"] as? Bool == true
                                original?.activate(options: [.activateIgnoringOtherApps])
                                self.writeVerification(report)
                            }
                        } else { self.writeVerification(report) }
                    }
                }
            }
        }
    }

    private func verifyFixtureClose(completion: @escaping ([String: Any]) -> Void) {
        // Only our disposable fixture is eligible. Never close a user's window
        // during automated verification.
        let fixtures = WindowCatalog.current().filter { $0.bundleID == "local.spacehop.close-fixture" }
        guard let disposable = fixtures.first(where: { $0.title == "Disposable window" }),
              let protected = fixtures.first(where: { $0.title == "Unsaved test window" }) else {
            completion(["success": false, "reason": "Missing disposable fixture"]); return
        }
        _ = WindowCatalog.focus(disposable)
        let closeRequested = WindowCatalog.close(disposable)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let onlyTargetClosed = WindowCatalog.element(pid: disposable.pid, id: disposable.id) == nil
                && WindowCatalog.element(pid: protected.pid, id: protected.id) != nil
                && NSRunningApplication(processIdentifier: protected.pid)?.isTerminated == false
            _ = WindowCatalog.focus(protected)
            let saveRequested = WindowCatalog.close(protected)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var raw: CFTypeRef?
                let element = WindowCatalog.element(pid: protected.pid, id: protected.id)
                if let element { AXUIElementCopyAttributeValue(element, "AXSheets" as CFString, &raw) }
                let saveDialog = (raw as? [AXUIElement])?.isEmpty == false
                completion(["success": closeRequested && onlyTargetClosed && saveRequested && saveDialog,
                            "exactWindowClosed": onlyTargetClosed, "saveDialogShown": saveDialog,
                            "unsavedWindowRetained": element != nil])
            }
        }
    }

    // Opt-in integration check: send the actual hotkeys through the event tap,
    // observe the destination, and return to the original Space.
    private func verifyHotkeys() {
        guard let initial = switcher.reader.read(), initial.ids.count > 1 else {
            writeVerification(["success": false, "reason": "Need at least two Spaces"])
            return
        }
        let direction: Direction = initial.destination(.right) == nil ? .left : .right
        guard let target = initial.destination(direction) else { return }
        let initialHandled = switcher.handledHotkeys
        let initialVerified = switcher.verifiedTransitions
        postHotkey(direction)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let outward = self.switcher.reader.read()?.id == initial.ids[target]
            if outward { self.postHotkey(direction == .left ? .right : .left) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let restored = self.switcher.reader.read()?.id == initial.id
                let handled = self.switcher.handledHotkeys - initialHandled
                let verified = self.switcher.verifiedTransitions - initialVerified
                self.writeVerification(["success": outward && restored && handled >= 2 && verified == 2,
                                        "outwardSwitch": outward, "originalSpaceRestored": restored,
                                        "hotkeysIntercepted": handled, "transitionsConfirmed": verified])
            }
        }
    }

    private func postHotkey(_ direction: Direction) {
        let key: CGKeyCode = direction == .left ? 123 : 124
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
            event.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            event.post(tap: .cghidEventTap)
        }
    }

    private func writeVerification(_ report: [String: Any]) {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--report=") }),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let path = String(argument.dropFirst("--report=".count))
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { NSLog("SpaceHop: failed to save integration report: %@", error.localizedDescription) }
    }

    @objc private func showGestureSettings() { overview.dismiss(restore: false); gestureSettings.show() }
    @objc private func togglePause() { overview.dismiss(restore: false); horizontalGestures.reset(); gestures.reset(); switcher.setEnabled(!switcher.enabled); lastStatus = ""; refresh() }
    @objc private func left() { switcher.move(.left) }
    @objc private func right() { switcher.move(.right) }
    @objc private func showOverview() { overview.toggle() }
    @objc private func showApplicationOverview() { overview.toggle(scope: .application) }
    @objc private func toggleSwipe() {
        gestures.reset(); gestures.enabled.toggle()
        UserDefaults.standard.set(gestures.enabled, forKey: "overviewSwipeEnabled")
        refresh()
    }
    @objc private func allowPreviews() { overview.requestPreviews() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Автозапуск", "Не удалось изменить автозапуск: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    @objc private func showHelp() {
        alert("SpaceHop", "Ctrl + ←/→ — быстрые переходы между Spaces.\nCtrl + ↑ или свайп вверх — обзор окон текущего Space.\nCtrl + ↓ или свайп вниз из окна — обзор активного приложения на текущем Space.\n\nВсе карточки одного размера. Окна отсортированы по приложению и заголовку. Клик или Enter открывает выбранное окно, Esc или свайп вниз закрывает обзор.\n\nДля превью разреши SpaceHop в «Конфиденциальность и безопасность → Запись экрана». Без этого доступны иконки и названия.\n\nМгновенные свайпы влево/вправо и их чувствительность — в «Настройки жестов трекпада» через значок SpaceHop. Автозапуск, пауза и отключение обзора свайпами — в меню. Приложение не меняет системные горячие клавиши или SIP.")
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }

    private func showWelcome() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 235),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SpaceHop"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Быстрое переключение Spaces")
        heading.font = .boldSystemFont(ofSize: 19)
        heading.frame = NSRect(x: 24, y: 171, width: 414, height: 30)
        let text = NSTextField(wrappingLabelWithString: "Разреши SpaceHop в разделе «Универсальный доступ», затем используй Ctrl + ←/→.\n\nУправление и выход — через значок в строке меню.")
        text.font = .systemFont(ofSize: 14)
        text.frame = NSRect(x: 24, y: 65, width: 410, height: 95)
        let button = NSButton(title: "Открыть настройки доступа", target: self, action: #selector(openAccessibility))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 22, y: 20, width: 285, height: 34)
        window.contentView?.addSubview(heading)
        window.contentView?.addSubview(text)
        window.contentView?.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcome = window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AXIsProcessTrusted() { showWelcome() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { overview.dismiss(restore: false); timer?.invalidate(); switcher.stop() }
}

func selfTest() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    let first = SpaceState(display: "Test", ids: [10, 20, 30], index: 0)
    let last = SpaceState(display: "Test", ids: [10, 20, 30], index: 2)
    check(first.destination(.left) == nil, "left edge")
    check(first.destination(.right) == 1, "right target")
    check(last.destination(.right) == nil, "right edge")
    check(last.destination(.left) == 1, "left target")
    check(shortcutDirection(key: 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]) == .left,
          "Ctrl+left includes arrow flags")
    check(shortcutDirection(key: 124, flags: .maskControl) == .right, "Ctrl+right")
    for flags: CGEventFlags in [[], .maskCommand, [.maskControl, .maskShift], [.maskControl, .maskAlternate], [.maskControl, .maskCommand]] {
        check(shortcutDirection(key: 123, flags: flags) == nil, "unrelated shortcuts pass through")
    }
    check(shortcutDirection(key: 125, flags: .maskControl) == nil, "Ctrl+down passes through")
    for direction: Direction in [.left, .right] {
        guard let events = DockGesture.events(direction) else { exit(1) }
        check(events.count == 3, "three gesture phases")
        for (event, phase) in zip(events, [Int64(1), 2, 4]) {
            check(event.getIntegerValueField(DockGesture.field(132)) == phase, "gesture phase")
            check(event.getIntegerValueField(DockGesture.field(55)) == 30, "Dock event type")
            check(event.getIntegerValueField(DockGesture.field(110)) == 23, "Dock HID type")
            check(event.getIntegerValueField(DockGesture.field(123)) == 1, "horizontal gesture")
            let progress = event.getDoubleValueField(DockGesture.field(124))
            check(abs(progress) > 0 && abs(progress) < 0.001, "minimal nonzero progress")
            check(progress * Double(direction.rawValue) > 0, "direction preserved")
            check(event.flags.isEmpty, "no modifier leakage")
        }
    }
    print("PASS: edge handling, hotkey isolation, gesture phases and direction")
}

@main
enum SpaceHopMain {
static func main() throws {
if CommandLine.arguments.contains("--self-test") {
    selfTest()
    overviewTests()
    verticalGestureTests()
    horizontalGestureTests()
} else if CommandLine.arguments.contains("--diagnostics") {
    let reader = SpaceReader()
    let state = reader.read()
    let info: [String: Any] = ["macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                             "accessibility": AXIsProcessTrusted(), "spacesReadable": state != nil,
                             "spaceCount": state?.ids.count ?? 0, "currentSpace": (state?.index ?? -1) + 1]
    let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
}
}
