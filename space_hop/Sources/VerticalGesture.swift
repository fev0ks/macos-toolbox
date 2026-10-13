import AppKit

// macOS 15 Dock-swipe fields: axis 2 is the system vertical three/four-finger
// gesture. Horizontal system swipes are handled by HorizontalGestureRouter.
final class VerticalGestureRouter {
    enum Mode { case idle, undecided, passthrough, captured }
    private var mode: Mode = .idle
    private var buffered: [CGEvent] = []
    private var suppressCompanionUntil = 0.0
    var enabled = UserDefaults.standard.object(forKey: "overviewSwipeEnabled") as? Bool ?? true
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onApplication: (() -> Void)?
    var overviewVisible: (() -> Bool)?
    private(set) var upwardCount = 0
    private(set) var downwardCloseCount = 0

    func handle(_ event: CGEvent, proxy: CGEventTapProxy) -> Bool {
        guard enabled else { return false }
        let type = event.getIntegerValueField(DockGesture.field(55))
        if type == 29 {
            if mode == .undecided { if let copy = event.copy() { buffered.append(copy) }; return true }
            return mode == .captured || ProcessInfo.processInfo.systemUptime < suppressCompanionUntil
        }
        guard type == 30,
              event.getIntegerValueField(DockGesture.field(110)) == 23,
              event.getIntegerValueField(DockGesture.field(123)) == 2 else { return false }
        let phase = event.getIntegerValueField(DockGesture.field(132))
        let progress = event.getDoubleValueField(DockGesture.field(124))
        let velocity = event.getDoubleValueField(DockGesture.field(130))
        if phase == 1 {
            mode = .undecided
            buffered.removeAll()
        }
        if mode == .idle { return false }
        if mode == .passthrough {
            if phase == 4 || phase == 8 { mode = .idle }
            return false
        }
        if mode == .undecided {
            if let copy = event.copy() { buffered.append(copy) }
            let direction = Self.direction(progress: progress, velocity: velocity, ended: phase == 4)
            if direction > 0 {
                buffered.removeAll()
                mode = .captured
                upwardCount += 1
                DispatchQueue.main.async { [weak self] in self?.onUp?() }
                NSLog("SpaceHop: upward system gesture intercepted")
            } else if direction < 0 {
                if overviewVisible?() == true {
                    buffered.removeAll()
                    mode = .captured
                    downwardCloseCount += 1
                    DispatchQueue.main.async { [weak self] in self?.onDown?() }
                } else {
                    buffered.removeAll()
                    mode = .captured
                    DispatchQueue.main.async { [weak self] in self?.onApplication?() }
                }
            } else if buffered.count > 80 {
                for replay in buffered { replay.tapPostEvent(proxy) }
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

    static func direction(progress: Double, velocity: Double, ended: Bool) -> Int {
        if progress > 0.025 { return 1 }
        if progress < -0.025 { return -1 }
        if ended && abs(velocity) > 0.08 { return velocity > 0 ? 1 : -1 }
        return 0
    }

    func reset() { mode = .idle; buffered.removeAll(); suppressCompanionUntil = 0 }
}

func verticalGestureTests() {
    guard VerticalGestureRouter.direction(progress: 0.03, velocity: 0, ended: false) == 1,
          VerticalGestureRouter.direction(progress: -0.03, velocity: 0, ended: false) == -1,
          VerticalGestureRouter.direction(progress: 0.001, velocity: 0, ended: false) == 0,
          VerticalGestureRouter.direction(progress: 0.001, velocity: 1, ended: true) == 1 else {
        fputs("FAIL: vertical gesture direction/threshold\n", stderr); exit(1)
    }
    print("PASS: vertical gesture direction and accidental-motion threshold")
}
