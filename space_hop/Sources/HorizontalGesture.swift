import AppKit

// Only Dock's horizontal system swipe is captured. Ordinary scroll-wheel
// events, app swipes and our tagged synthetic Dock gestures pass unchanged.
final class HorizontalGestureRouter {
    enum Mode { case idle, undecided, passthrough, captured }
    private let defaults: UserDefaults
    private var mode: Mode = .idle
    private var buffered: [CGEvent] = []
    private var suppressCompanionUntil = 0.0
    var enabled: Bool { didSet {
        defaults.set(enabled, forKey: "instantSpaceSwipeEnabled")
        if !enabled { reset() }
    } }
    var sensitivity: Double { didSet {
        sensitivity = min(100, max(1, sensitivity.isFinite ? sensitivity : 75))
        defaults.set(sensitivity, forKey: "spaceSwipeSensitivity")
    } }
    var reversed: Bool { didSet { defaults.set(reversed, forKey: "spaceSwipeReversed") } }
    var canBegin: (() -> Bool)?
    var onSwitch: ((Direction) -> Void)?
    private(set) var handledSwipes = 0
    var threshold: Double { 0.015 + (100 - sensitivity) * 0.0014 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "instantSpaceSwipeEnabled") as? Bool ?? true
        let value = defaults.object(forKey: "spaceSwipeSensitivity") as? Double ?? 75
        sensitivity = min(100, max(1, value.isFinite ? value : 75))
        reversed = defaults.object(forKey: "spaceSwipeReversed") as? Bool ?? false
    }

    func handle(_ event: CGEvent, proxy: CGEventTapProxy) -> Bool {
        handle(event, replay: { $0.tapPostEvent(proxy) })
    }

    func handle(_ event: CGEvent, replay: (CGEvent) -> Void) -> Bool {
        guard enabled, !DockGesture.isSynthetic(event) else { return false }
        let type = event.getIntegerValueField(DockGesture.field(55))
        if type == 29 {
            if mode == .undecided {
                if let copy = event.copy() { buffered.append(copy) }
                return true
            }
            return mode == .captured || ProcessInfo.processInfo.systemUptime < suppressCompanionUntil
        }
        guard type == 30, event.getIntegerValueField(DockGesture.field(110)) == 23 else { return false }
        let phase = event.getIntegerValueField(DockGesture.field(132))
        guard event.getIntegerValueField(DockGesture.field(123)) == 1 else {
            if phase == 1 { reset() }
            return false
        }
        if phase == 1 {
            suppressCompanionUntil = 0
            buffered.removeAll()
            mode = canBegin?() == false ? .passthrough : .undecided
        }
        if mode == .idle { return false }
        if mode == .passthrough {
            if phase == 4 || phase == 8 { mode = .idle }
            return false
        }
        if mode == .undecided {
            if let copy = event.copy() { buffered.append(copy) }
            let progress = event.getDoubleValueField(DockGesture.field(124))
            if phase != 8, progress.isFinite, abs(progress) >= threshold {
                buffered.removeAll()
                mode = .captured
                handledSwipes += 1
                let sign = progress * (reversed ? -1 : 1)
                onSwitch?(sign < 0 ? .left : .right)
            } else if buffered.count > 80 {
                // Unrecognized input must recover native handling rather than
                // holding an unbounded stream of events in memory.
                for copy in buffered { replay(copy) }
                buffered.removeAll()
                mode = .passthrough
                return true
            }
        }
        if phase == 4 || phase == 8 {
            buffered.removeAll()
            mode = .idle
            suppressCompanionUntil = ProcessInfo.processInfo.systemUptime + 0.025
        }
        return true
    }

    func reset() { mode = .idle; buffered.removeAll(); suppressCompanionUntil = 0 }
}

func horizontalGestureTests() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    let suite = "local.spacehop.test.swipes.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let router = HorizontalGestureRouter(defaults: defaults)
    var moves: [Direction] = []
    router.onSwitch = { moves.append($0) }
    func event(phase: Int64, progress: Double, axis: Int64 = 1, type: Int64 = 30) -> CGEvent {
        let e = CGEvent(source: nil)!
        e.setIntegerValueField(DockGesture.field(55), value: type)
        e.setIntegerValueField(DockGesture.field(110), value: 23)
        e.setIntegerValueField(DockGesture.field(123), value: axis)
        e.setIntegerValueField(DockGesture.field(132), value: phase)
        e.setDoubleValueField(DockGesture.field(124), value: progress)
        return e
    }
    var replayed = 0
    func route(_ e: CGEvent) -> Bool { router.handle(e, replay: { _ in replayed += 1 }) }
    check(route(event(phase: 1, progress: 0)), "capture beginning before native animation")
    check(route(event(phase: 2, progress: 0.001)) && moves.isEmpty, "ignore accidental short motion")
    check(route(event(phase: 2, progress: 0.10)), "capture intentional movement")
    _ = route(event(phase: 2, progress: 0.5)); _ = route(event(phase: 2, progress: -0.5))
    _ = route(event(phase: 4, progress: 0.7))
    check(moves == [.right], "long swipe and reversal trigger only once")
    _ = route(event(phase: 1, progress: 0)); _ = route(event(phase: 2, progress: -0.10))
    _ = route(event(phase: 4, progress: -0.2)); check(moves == [.right, .left], "next gesture switches again")
    _ = route(event(phase: 1, progress: 0)); _ = route(event(phase: 8, progress: 0.6))
    check(moves.count == 2, "cancelled gesture cannot trigger")
    router.reset()
    check(!route(event(phase: 1, progress: 0.6, axis: 2)), "vertical overview gesture passes")
    check(!route(event(phase: 2, progress: 0.6, type: 22)), "ordinary two-finger scrolling passes")
    check(!route(event(phase: 2, progress: 0.6)), "orphan gesture update passes")
    _ = route(event(phase: 1, progress: 0))
    for synthetic in DockGesture.events(.right)! { check(!route(synthetic), "own Dock events pass without reentry") }
    check(moves.count == 2, "synthetic transition does not change physical gesture state")
    _ = route(event(phase: 2, progress: -0.1)); _ = route(event(phase: 4, progress: -0.1))
    check(moves.last == .left && moves.count == 3, "physical gesture survives interleaved synthetic events")
    router.reversed = true; router.sensitivity = 100
    _ = route(event(phase: 1, progress: 0)); _ = route(event(phase: 2, progress: 0.02)); _ = route(event(phase: 4, progress: 0.02))
    check(moves.last == .left && moves.count == 4, "live sensitivity and reversed direction")
    router.sensitivity = 1
    _ = route(event(phase: 1, progress: 0)); _ = route(event(phase: 2, progress: 0.1)); _ = route(event(phase: 4, progress: 0.1))
    check(moves.count == 4, "low sensitivity requires longer movement")
    router.canBegin = { false }
    check(!route(event(phase: 1, progress: 0)), "unknown Space falls back to native")
    check(!route(event(phase: 2, progress: 0.8)) && !route(event(phase: 4, progress: 0.8)), "entire fallback sequence passes")
    router.canBegin = { true }; router.reset()
    _ = route(event(phase: 1, progress: 0))
    for _ in 0..<85 { _ = route(event(phase: 2, progress: 0.001)) }
    check(replayed == 81 && moves.count == 4, "bounded buffering replays native sequence once")
    router.enabled = false
    check(!route(event(phase: 1, progress: 1)), "disabled feature passes native gesture")
    let loaded = HorizontalGestureRouter(defaults: defaults)
    check(!loaded.enabled && loaded.sensitivity == 1 && loaded.reversed, "preferences persist across restarts")
    print("PASS: horizontal swipe capture, one transition, thresholds, cancellation, native fallback, scroll isolation, synthetic reentry protection, live persisted settings")
}
