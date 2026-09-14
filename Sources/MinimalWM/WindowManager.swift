import Cocoa
import CoreGraphics

@MainActor
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var isEnabled = false
    @Published var floatingWindows: Set<AXUIElement> = []

    private var config: Config
    private var tileGeneration = 0
    private var suppressUntil: CFAbsoluteTime = 0

    private var dragWindow: AXUIElement?
    private var dragPID: pid_t = 0
    private var dragLastFrame: CGRect?
    private var lastMoveTime = CFAbsoluteTime(0)
    private var quietTimer: Timer?
    private var dragPollTimer: Timer?
    private var dragOrder: [AXUIElement] = []
    private var dragOriginalOrder: [AXUIElement] = []
    private var dragDisplayFrame: CGRect?
    private var dragPreviewIndex: Int?
    private var dragCandidateIndex: Int?
    private var dragCandidateSamples = 0
    private var dragHasValidDrop = false
    private var frameAnimationTimer: Timer?
    private var animationStates: [AXUIElement: WindowAnimationState] = [:]
    private var animationWindows: Set<AXUIElement> = []
    private var animationPIDs: Set<pid_t> = []
    private var animationStartedAt = CFAbsoluteTime(0)
    private var lastAnimationTickAt = CFAbsoluteTime(0)
    private var animationTickCount = 0
    private var animationWriteCount = 0
    private var animationSlowTickCount = 0
    private var animationWriteTime = TimeInterval(0)
    private var displayOrders: [String: [ManagedWindowKey]] = [:]
    private var displayElements: [ManagedWindowKey: AXUIElement] = [:]
    private let dragConfirmInterval: TimeInterval = 0.25
    private let dragQuietInterval: TimeInterval = 0.3
    private let dragPollInterval: TimeInterval = 1.0 / 60.0
    private let dragAnimationDuration: TimeInterval = 0.14
    private let frameAnimationInterval: TimeInterval = 1.0 / 120.0
    private let dragHysteresis: CGFloat = 24

    private struct WindowAnimationState {
        var frame: CGRect
        var lastWrittenFrame: CGRect
        var lastWriteAt: CFAbsoluteTime
        var velocity: CGVector
        var sizeVelocity: CGSize
        var target: CGRect
    }

    private struct ManagedWindowKey: Hashable {
        let pid: pid_t
        let identity: String
        let subrole: String
    }

    private init() {
        self.config = Config.load()
        self.outerGap = config.outerGap
        self.innerGap = config.innerGap
        self.isGapsSynced = config.syncGaps
        self.masterRatio = config.masterRatio
    }

    nonisolated func loadConfig() {
        Task { @MainActor in
            self.config = Config.load()
            self.outerGap = config.outerGap
            self.innerGap = config.innerGap
            self.isGapsSynced = config.syncGaps
            self.masterRatio = config.masterRatio
            self.tileAll()
        }
    }

    // MARK: - Toggle

    func toggle() {
        isEnabled.toggle()
        if isEnabled {
            tileAll()
        } else {
            stopAnimations()
            quietTimer?.invalidate()
            resetDragState()
        }
    }

    @Published var outerGap: CGFloat
    @Published var innerGap: CGFloat
    @Published var isGapsSynced: Bool
    @Published var masterRatio: CGFloat

    func setOuterGap(_ v: CGFloat) {
        if isGapsSynced {
            isGapsSynced = false
            config.syncGaps = false
        }
        config.outerGap = v
        outerGap = v
        applyTilesNow()
    }

    func setInnerGap(_ v: CGFloat) {
        if isGapsSynced {
            isGapsSynced = false
            config.syncGaps = false
        }
        config.innerGap = v
        innerGap = v
        applyTilesNow()
    }

    func setGapsSynced(_ enabled: Bool) {
        isGapsSynced = enabled
        config.syncGaps = enabled
        if enabled {
            setGaps(outerGap, synchronized: true)
        } else {
            applyTilesNow()
        }
        commitConfig()
    }

    private func setGaps(_ value: CGFloat, synchronized: Bool) {
        let clamped = max(0, min(40, value))
        outerGap = clamped
        innerGap = synchronized ? clamped : innerGap
        config.outerGap = outerGap
        config.innerGap = innerGap
        applyTilesNow()
    }

    func setMasterRatio(_ v: CGFloat) {
        let clamped = max(0.2, min(0.8, v))
        config.masterRatio = clamped
        masterRatio = clamped
        applyTilesNow()
    }

    func commitConfig() {
        config.save()
    }

    // User-initiated tile (sliders, hotkeys) — bypasses event suppression.
    private func applyTilesNow() {
        guard isEnabled else { return }
        suppressUntil = 0
        tileAll()
    }

    // MARK: - Tiling

    func tileAll() {
        guard isEnabled else { return }
        guard dragWindow == nil else { return }
        if CFAbsoluteTimeGetCurrent() < suppressUntil { return }

        tileGeneration &+= 1
        let gen = tileGeneration

        var didChange = false
        let activeDisplays = DisplayTracker.currentDisplays()
        for screen in activeDisplays {
            let frame = LayoutEngine.visibleFrameInCG(for: screen)
            let windows = orderedWindows(on: frame, screen: screen)

            guard gen == tileGeneration else { return }

            let elements = windows
            let dragged = dragWindow
            if layoutNeedsUpdate(elements, in: frame, config: config, excluding: dragged) {
                animateTiles(
                    elements,
                    in: frame,
                    excluding: dragged,
                    duration: dragAnimationDuration
                )
                didChange = true
            }
        }

        if didChange {
            suppressUntil = CFAbsoluteTimeGetCurrent() + 0.1
        }
    }

    func tileAllIfSpaceChanged() {
        guard isEnabled else { return }
        tileAll()
    }

    // MARK: - Window drag handling

    func handleWindowEvent(_ name: String, element: AXUIElement) {
        guard isEnabled else { return }
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            handleMove(of: element)
        case kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            guard dragWindow == nil else { return }
            tileAll()
        default:
            break
        }
    }

    private func handleMove(of window: AXUIElement) {
        let now = CFAbsoluteTimeGetCurrent()

        // Safari and some other applications briefly expose title-bar
        // elements as AXUnknown while a real window is being moved. They are
        // not valid drag sources and must never start a drag session.
        guard AXBridge.subrole(window) == "AXStandardWindow",
              let frame = AXBridge.frame(of: window),
              frame.width > 100,
              frame.height > 100 else {
            return
        }

        // Ignore notifications emitted by the manager immediately after an
        // animation settles. The short grace period prevents the final AX
        // write from being interpreted as a fresh user drag.
        if dragWindow == nil, now < suppressUntil {
            return
        }

        // Ignore movement notifications only for windows currently written by
        // the animation loop. A time-based global suppression can swallow the
        // first real drag event after a layout settles.
        if frameAnimationTimer != nil, animationWindows.contains(window) {
            return
        }
        if frameAnimationTimer != nil,
           dragWindow == nil,
           animationPIDs.contains(AXBridge.pid(of: window)) {
            return
        }

        // Preview animation moves the other windows while the dragged window
        // remains under the user's control.
        if let dragged = dragWindow, dragged != window {
            return
        }

        // A window being dragged fires a rapid stream of move events. Keep
        // the preview responsive and use a quiet period to detect the drop.
        if let dragged = dragWindow, dragged == window {
            lastMoveTime = now
            dragLastFrame = AXBridge.frame(of: window) ?? dragLastFrame
            updateDragPreview(of: dragged)
            scheduleQuietCheck(interval: dragQuietInterval)
            return
        }

        dragWindow = window
        beginDrag(of: window)
        if isDebugEnabled {
            mwLog("minimalWM: drag started pid=\(AXBridge.pid(of: window))")
        }
        lastMoveTime = now
        dragLastFrame = AXBridge.frame(of: window)
        updateDragPreview(of: window)
        scheduleQuietCheck(interval: dragConfirmInterval)
    }

    private func beginDrag(of dragged: AXUIElement) {
        guard let frame = AXBridge.frame(of: dragged),
              let screen = DisplayTracker.currentDisplays().first(where: {
                  LayoutEngine.visibleFrameInCG(for: $0).contains(
                      CGPoint(x: frame.midX, y: frame.midY)
                  )
              }) else {
                  resetDragState()
                  return
              }

        let displayFrame = LayoutEngine.visibleFrameInCG(for: screen)
        let windows = orderedWindows(on: displayFrame, screen: screen)

        dragOrder = windows
        dragOriginalOrder = windows
        dragDisplayFrame = displayFrame
        dragPreviewIndex = windows.firstIndex(of: dragged)
        dragCandidateIndex = nil
        dragCandidateSamples = 0
        dragHasValidDrop = false
        dragPID = AXBridge.pid(of: dragged)
        startDragPolling()
    }

    private func startDragPolling() {
        dragPollTimer?.invalidate()
        let timer = Timer(timeInterval: dragPollInterval, repeats: true) { [weak self] _ in
            self?.pollDraggedWindow()
        }
        dragPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollDraggedWindow() {
        guard let dragged = dragWindow else {
            dragPollTimer?.invalidate()
            dragPollTimer = nil
            return
        }

        guard let frame = AXBridge.frame(of: dragged) else {
            if dragPID != 0,
               let replacement = AXBridge.windows(for: dragPID).first(where: {
                   AXBridge.subrole($0) == "AXStandardWindow"
               }) {
                let previous = dragged
                dragWindow = replacement
                dragLastFrame = AXBridge.frame(of: replacement)
                dragOrder = dragOrder.map { $0 == previous ? replacement : $0 }
                dragOriginalOrder = dragOriginalOrder.map { $0 == previous ? replacement : $0 }
                dragPreviewIndex = dragOrder.firstIndex(of: replacement)
                if isDebugEnabled {
                    mwLog("minimalWM: drag AX element recovered pid=\(dragPID)")
                }
                updateDragPreview(of: replacement)
            }
            return
        }

        guard dragLastFrame != frame else { return }
        dragLastFrame = frame
        lastMoveTime = CFAbsoluteTimeGetCurrent()
        updateDragPreview(of: dragWindow ?? dragged)
        scheduleQuietCheck(interval: dragQuietInterval)
        if isDebugEnabled {
            mwLog("minimalWM: drag polled frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
        }
    }

    private func updateDragPreview(of dragged: AXUIElement) {
        guard let draggedFrame = AXBridge.frame(of: dragged),
              let screen = DisplayTracker.currentDisplays().first(where: {
                  LayoutEngine.visibleFrameInCG(for: $0).contains(
                      CGPoint(x: draggedFrame.midX, y: draggedFrame.midY)
                  )
              }) else { return }

        let frame = LayoutEngine.visibleFrameInCG(for: screen)
        if let previousFrame = dragDisplayFrame,
           previousFrame != frame {
            let sourceScreen = DisplayTracker.currentDisplays().first {
                LayoutEngine.visibleFrameInCG(for: $0) == previousFrame
            }
            let sourceWindows = sourceScreen.map {
                orderedWindows(on: previousFrame, screen: $0)
                    .filter { $0 != dragged }
            } ?? []
            animateTiles(sourceWindows, in: previousFrame, duration: dragAnimationDuration)

            dragOrder = orderedWindows(on: frame, screen: screen)
            dragOriginalOrder = dragOrder
            dragPreviewIndex = dragOrder.firstIndex(of: dragged)
            dragCandidateIndex = nil
            dragCandidateSamples = 0
            dragHasValidDrop = false
            dragDisplayFrame = frame
            if isDebugEnabled {
                mwLog("minimalWM: drag moved to display \(frame)")
            }
        }

        guard let currentIndex = dragOrder.firstIndex(of: dragged) else { return }

        let tiles = LayoutEngine.computeTiles(
            for: dragOrder.count,
            in: frame,
            outerGap: config.outerGap,
            innerGap: config.innerGap,
            masterRatio: config.masterRatio
        )
        let center = CGPoint(x: draggedFrame.midX, y: draggedFrame.midY)
        guard let targetIndex = insertionIndex(
            for: center,
            tiles: tiles,
            currentIndex: currentIndex
        ) else {
            dragHasValidDrop = false
            dragCandidateIndex = nil
            dragCandidateSamples = 0
            return
        }
        dragHasValidDrop = true
        guard targetIndex != currentIndex else {
            dragCandidateIndex = nil
            dragCandidateSamples = 0
            return
        }

        if dragCandidateIndex == targetIndex {
            dragCandidateSamples += 1
        } else {
            dragCandidateIndex = targetIndex
            dragCandidateSamples = 1
        }
        guard dragCandidateSamples >= 3 else { return }

        var reordered = dragOrder
        reordered.remove(at: currentIndex)
        reordered.insert(dragged, at: min(targetIndex, reordered.count))
        dragOrder = reordered
        dragPreviewIndex = targetIndex
        dragCandidateIndex = nil
        dragCandidateSamples = 0
        if isDebugEnabled {
            mwLog("minimalWM: drag preview slot=\(targetIndex)")
        }

        animateTiles(
            reordered,
            in: frame,
            excluding: dragged,
            duration: dragAnimationDuration
        )
    }

    private func insertionIndex(
        for center: CGPoint,
        tiles: [LayoutEngine.Tile],
        currentIndex: Int
    ) -> Int? {
        guard let master = tiles.first else { return nil }
        let stack = Array(tiles.dropFirst())
        guard !stack.isEmpty else {
            return master.frame.insetBy(dx: -dragHysteresis, dy: -dragHysteresis).contains(center)
                ? 0
                : nil
        }

        let masterBoundary = (master.frame.maxX + stack.first!.frame.minX) / 2
        let inWorkArea = tiles.contains {
            $0.frame.insetBy(dx: -dragHysteresis, dy: -dragHysteresis).contains(center)
        }
        guard inWorkArea else { return nil }

        if currentIndex == 0 {
            if center.x < masterBoundary + dragHysteresis {
                return 0
            }
        } else if center.x < masterBoundary - dragHysteresis {
            return 0
        } else if center.x > masterBoundary - dragHysteresis {
            let stackIndex = stack.enumerated().min {
                abs(center.y - $0.element.frame.midY) < abs(center.y - $1.element.frame.midY)
            }?.offset ?? 0
            return stackIndex + 1
        }

        if currentIndex == 0 {
            return center.x <= masterBoundary ? 0 : 1
        }

        let currentStackIndex = currentIndex - 1
        guard currentStackIndex < stack.count else { return nil }
        let currentSlot = stack[currentStackIndex].frame
        if abs(center.y - currentSlot.midY) <= currentSlot.height / 2 + dragHysteresis {
            return currentIndex
        }

        let targetStackIndex = stack.enumerated().min {
            abs(center.y - $0.element.frame.midY) < abs(center.y - $1.element.frame.midY)
        }?.offset ?? currentStackIndex
        return targetStackIndex + 1
    }

    private func resetDragState() {
        dragPollTimer?.invalidate()
        dragPollTimer = nil
        dragWindow = nil
        dragPID = 0
        dragLastFrame = nil
        dragOrder = []
        dragOriginalOrder = []
        dragDisplayFrame = nil
        dragPreviewIndex = nil
        dragCandidateIndex = nil
        dragCandidateSamples = 0
        dragHasValidDrop = false
    }

    private func stopAnimations() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        animationStates.removeAll()
        animationWindows.removeAll()
        animationPIDs.removeAll()
        suppressUntil = 0
    }

    private func scheduleQuietCheck(interval: TimeInterval) {
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.quietCheck()
        }
        quietTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func quietCheck() {
        let now = CFAbsoluteTimeGetCurrent()
        guard let dragged = dragWindow else { return }

        // AX move notifications can pause while the user is still holding the
        // title bar. Never commit a drop based on notification silence alone.
        guard !isPrimaryMouseButtonDown() else {
            scheduleQuietCheck(interval: dragQuietInterval)
            return
        }

        // Still receiving moves — keep waiting for the drop.
        if now - lastMoveTime < 0.05 {
            scheduleQuietCheck(interval: 0.1)
            return
        }

        handleDrop(of: dragged)
    }

    private func isPrimaryMouseButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    private func handleDrop(of dragged: AXUIElement) {
        guard isEnabled else { return }

        guard let draggedFrame = AXBridge.frame(of: dragged) else {
            tileAll()
            return
        }

        let draggedCenter = CGPoint(x: draggedFrame.midX, y: draggedFrame.midY)

        guard let screen = DisplayTracker.currentDisplays().first(where: {
            LayoutEngine.visibleFrameInCG(for: $0).contains(draggedCenter)
        }) else {
            tileAll()
            return
        }
        let frame = LayoutEngine.visibleFrameInCG(for: screen)

        var tiled = orderedWindows(on: frame, screen: screen)

        guard tiled.contains(dragged) else {
            tileAll()
            return
        }

        if dragHasValidDrop,
           let previewIndex = dragPreviewIndex,
           !dragOrder.isEmpty,
           dragOrder.contains(dragged),
           previewIndex < dragOrder.count {
            tiled = dragOrder
        } else if !dragOriginalOrder.isEmpty {
            tiled = dragOriginalOrder
            if isDebugEnabled {
                mwLog("minimalWM: drag drop invalid, restoring original order")
            }
        }

        persistOrder(tiled, for: screen)
        tileGeneration &+= 1
        animateTiles(tiled, in: frame, duration: dragAnimationDuration)
        if isDebugEnabled {
            mwLog("minimalWM: drag committed")
        }
        resetDragState()
    }

    private func animateTiles(
        _ windows: [AXUIElement],
        in frame: CGRect,
        excluding excludedWindow: AXUIElement? = nil,
        duration: TimeInterval
    ) {
        let tiled = windows.filter {
            !floatingWindows.contains($0) && $0 != excludedWindow
        }
        let tiles = LayoutEngine.computeTiles(
            for: windows.filter { !floatingWindows.contains($0) }.count,
            in: frame,
            outerGap: config.outerGap,
            innerGap: config.innerGap,
            masterRatio: config.masterRatio
        )

        let targets: [(AXUIElement, CGRect)] = tiled.compactMap { window in
            guard let index = windows.firstIndex(of: window),
                  index < tiles.count,
                  AXBridge.frame(of: window) != nil else { return nil }
            return (window, tiles[index].frame)
        }

        let targetWindows = Set(targets.map(\.0))
        animationWindows = targetWindows
        animationPIDs = Set(targetWindows.map(AXBridge.pid(of:)))
        for window in Array(animationStates.keys) where !targetWindows.contains(window) {
            animationStates.removeValue(forKey: window)
        }

        for (window, target) in targets {
            if var state = animationStates[window] {
                state.target = target
                animationStates[window] = state
            } else if let current = AXBridge.frame(of: window) {
                animationStates[window] = WindowAnimationState(
                    frame: current,
                    lastWrittenFrame: current,
                    lastWriteAt: 0,
                    velocity: .zero,
                    sizeVelocity: .zero,
                    target: target
                )
            }
        }

        if excludedWindow == nil {
            suppressUntil = CFAbsoluteTimeGetCurrent() + duration + 0.1
        }

        guard frameAnimationTimer == nil else { return }

        animationStartedAt = CFAbsoluteTimeGetCurrent()
        lastAnimationTickAt = animationStartedAt
        animationTickCount = 0
        animationWriteCount = 0
        animationSlowTickCount = 0
        animationWriteTime = 0
        if isDebugEnabled {
            mwLog("minimalWM: animation started windows=\(targets.count) targetDurationMs=\(Int(duration * 1000))")
        }

        let animationTimer = Timer(timeInterval: frameAnimationInterval, repeats: true) {
            [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let tickStartedAt = CFAbsoluteTimeGetCurrent()
            let tickInterval = tickStartedAt - self.lastAnimationTickAt
            self.lastAnimationTickAt = tickStartedAt
            self.animationTickCount += 1
            if tickInterval > 0.0167 {
                self.animationSlowTickCount += 1
            }

            // Accessibility writes can block the main run loop. Advance by
            // actual elapsed time so the spring remains time-consistent.
            let dt = min(max(tickInterval, self.frameAnimationInterval), 0.033)
            // A critically damped spring gives a fast, elastic response while
            // avoiding visible bounce when a target changes mid-flight.
            let stiffness: CGFloat = 625
            let damping: CGFloat = 50 // 2 * sqrt(stiffness)
            // Size changes use a softer spring so an app has time to redraw
            // its content as its bounds change, instead of visibly snapping.
            let sizeStiffness: CGFloat = 400
            let sizeDamping: CGFloat = 40 // 2 * sqrt(sizeStiffness)
            var settled = true

            for (window, var state) in self.animationStates {
                let previousFrame = state.frame
                let (x, vx) = springStep(
                    value: state.frame.origin.x,
                    velocity: state.velocity.dx,
                    target: state.target.origin.x,
                    stiffness: stiffness,
                    damping: damping,
                    dt: dt
                )
                let (y, vy) = springStep(
                    value: state.frame.origin.y,
                    velocity: state.velocity.dy,
                    target: state.target.origin.y,
                    stiffness: stiffness,
                    damping: damping,
                    dt: dt
                )
                let (width, widthVelocity) = springStep(
                    value: state.frame.width,
                    velocity: state.sizeVelocity.width,
                    target: state.target.width,
                    stiffness: sizeStiffness,
                    damping: sizeDamping,
                    dt: dt
                )
                let (height, heightVelocity) = springStep(
                    value: state.frame.height,
                    velocity: state.sizeVelocity.height,
                    target: state.target.height,
                    stiffness: sizeStiffness,
                    damping: sizeDamping,
                    dt: dt
                )

                state.frame.origin.x = x
                state.frame.origin.y = y
                state.frame.size.width = width
                state.frame.size.height = height
                state.velocity = CGVector(dx: vx, dy: vy)
                state.sizeVelocity = CGSize(width: widthVelocity, height: heightVelocity)

                state.frame.origin.x = clampedSpringValue(
                    previous: previousFrame.origin.x,
                    value: state.frame.origin.x,
                    target: state.target.origin.x
                )
                state.frame.origin.y = clampedSpringValue(
                    previous: previousFrame.origin.y,
                    value: state.frame.origin.y,
                    target: state.target.origin.y
                )
                state.frame.size.width = clampedSpringValue(
                    previous: previousFrame.width,
                    value: state.frame.width,
                    target: state.target.width
                )
                state.frame.size.height = clampedSpringValue(
                    previous: previousFrame.height,
                    value: state.frame.height,
                    target: state.target.height
                )

                let positionDistance = hypot(
                    state.target.origin.x - state.frame.origin.x,
                    state.target.origin.y - state.frame.origin.y
                )
                let sizeDistance = hypot(
                    state.target.width - state.frame.width,
                    state.target.height - state.frame.height
                )
                let speed = hypot(state.velocity.dx, state.velocity.dy)
                let sizeSpeed = hypot(state.sizeVelocity.width, state.sizeVelocity.height)

                if positionDistance < 0.5 && sizeDistance < 0.5 && speed < 8 && sizeSpeed < 8 {
                    state.frame = state.target
                    state.velocity = .zero
                    state.sizeVelocity = .zero
                } else {
                    settled = false
                }

                let writeDelta = max(
                    abs(state.lastWrittenFrame.origin.x - state.frame.origin.x),
                    abs(state.lastWrittenFrame.origin.y - state.frame.origin.y),
                    abs(state.lastWrittenFrame.width - state.frame.width),
                    abs(state.lastWrittenFrame.height - state.frame.height)
                )
                let now = CFAbsoluteTimeGetCurrent()
                // Limit synchronous AX writes to about 30 Hz per window. The
                // spring remains continuous while the main run loop stays
                // responsive to drag events.
                let canWrite = now - state.lastWriteAt >= 1.0 / 30.0
                if writeDelta > 0.75 && canWrite {
                    let writeStartedAt = CFAbsoluteTimeGetCurrent()
                    let sizeDelta = max(
                        abs(state.lastWrittenFrame.width - state.frame.width),
                        abs(state.lastWrittenFrame.height - state.frame.height)
                    )
                    AXBridge.setFrame(
                        window,
                        to: state.frame,
                        writeSize: sizeDelta > 1.5,
                        reinforcePosition: false
                    )
                    self.animationWriteTime += CFAbsoluteTimeGetCurrent() - writeStartedAt
                    self.animationWriteCount += 1
                    state.lastWrittenFrame = state.frame
                    state.lastWriteAt = now
                }
                self.animationStates[window] = state
            }

            if settled {
                for (window, state) in self.animationStates {
                    let finalDelta = max(
                        abs(state.lastWrittenFrame.origin.x - state.target.origin.x),
                        abs(state.lastWrittenFrame.origin.y - state.target.origin.y),
                        abs(state.lastWrittenFrame.width - state.target.width),
                        abs(state.lastWrittenFrame.height - state.target.height)
                    )
                    if finalDelta > 0.5 {
                        AXBridge.setFrame(window, to: state.target)
                    }
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - self.animationStartedAt
                if isDebugEnabled {
                    let averageTickMs = self.animationTickCount > 0
                        ? (elapsed / Double(self.animationTickCount)) * 1000
                        : 0
                    let averageWriteMs = self.animationWriteCount > 0
                        ? (self.animationWriteTime / Double(self.animationWriteCount)) * 1000
                        : 0
                    mwLog(
                        "minimalWM: animation settled elapsedMs=\(Int(elapsed * 1000)) " +
                        "ticks=\(self.animationTickCount) avgTickMs=\(String(format: "%.2f", averageTickMs)) " +
                        "slowTicks=\(self.animationSlowTickCount) writes=\(self.animationWriteCount) " +
                        "avgWriteMs=\(String(format: "%.2f", averageWriteMs))"
                    )
                }
                timer.invalidate()
                self.frameAnimationTimer = nil
                self.animationStates.removeAll()
                self.animationWindows.removeAll()
                self.animationPIDs.removeAll()
            }
        }
        frameAnimationTimer = animationTimer
        RunLoop.main.add(animationTimer, forMode: .common)
    }

    private func clampedSpringValue(
        previous: CGFloat,
        value: CGFloat,
        target: CGFloat
    ) -> CGFloat {
        let wasBeforeTarget = previous < target
        let crossedTarget = wasBeforeTarget ? value > target : value < target
        return crossedTarget ? target : value
    }

    private func springStep(
        value: CGFloat,
        velocity: CGFloat,
        target: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat,
        dt: CGFloat
    ) -> (value: CGFloat, velocity: CGFloat) {
        let displacement = target - value
        let acceleration = stiffness * displacement - damping * velocity
        let nextVelocity = velocity + acceleration * dt
        let nextValue = value + nextVelocity * dt
        return (
            clampedSpringValue(previous: value, value: nextValue, target: target),
            nextVelocity
        )
    }

    private func layoutNeedsUpdate(
        _ windows: [AXUIElement],
        in frame: CGRect,
        config: Config,
        excluding excludedWindow: AXUIElement?
    ) -> Bool {
        let tiled = windows.filter {
            !floatingWindows.contains($0) && $0 != excludedWindow
        }
        let tiles = LayoutEngine.computeTiles(
            for: windows.filter { !floatingWindows.contains($0) }.count,
            in: frame,
            outerGap: config.outerGap,
            innerGap: config.innerGap,
            masterRatio: config.masterRatio
        )

        return tiled.contains { window in
            guard let index = windows.firstIndex(of: window),
                  index < tiles.count,
                  let current = AXBridge.frame(of: window) else {
                return false
            }
            let target = tiles[index].frame
            return abs(current.origin.x - target.origin.x) > 2
                || abs(current.origin.y - target.origin.y) > 2
                || abs(current.width - target.width) > 2
                || abs(current.height - target.height) > 2
        }
    }

    // MARK: - Focus / Move

    func focusLeft() {
        guard let current = focusedWindow() else { return }
        let neighbors = neighbors(of: current, direction: -1)
        if let target = neighbors.first {
            _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func focusRight() {
        guard let current = focusedWindow() else { return }
        let neighbors = neighbors(of: current, direction: 1)
        if let target = neighbors.first {
            _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func swapLeft() { swapFocusedWindow(direction: -1) }
    func swapRight() { swapFocusedWindow(direction: 1) }

    func growMaster() {
        setMasterRatio(config.masterRatio + 0.05)
        commitConfig()
    }

    func shrinkMaster() {
        setMasterRatio(config.masterRatio - 0.05)
        commitConfig()
    }

    func toggleFloat() {
        guard let current = focusedWindow() else { return }
        if floatingWindows.contains(current) {
            floatingWindows.remove(current)
        } else {
            floatingWindows.insert(current)
        }
        tileAll()
    }

    // MARK: - Private

    private func orderedWindows(on frame: CGRect, screen: NSScreen) -> [AXUIElement] {
        let discovered = AXBridge.tiledWindows(on: frame, floatApps: config.floatApps)
            .filter {
                AXBridge.pid(of: $0.element) != ProcessInfo.processInfo.processIdentifier
                    && !floatingWindows.contains($0.element)
            }

        // Some apps, including Ghostty, can expose identical or empty window
        // titles and no AXIdentifier. Keep each AX window as a distinct item
        // instead of collapsing multiple terminal windows into one key.
        var seenKeys = Set<ManagedWindowKey>()
        let uniqueDiscovered = discovered.filter { item in
            seenKeys.insert(windowKey(for: item.element)).inserted
        }
        let currentKeys = uniqueDiscovered.map { windowKey(for: $0.element) }
        let currentSet = Set(currentKeys)
        let displayKey = displayIdentifier(for: screen)
        var order = displayOrders[displayKey, default: []]

        for (key, element) in zip(currentKeys, uniqueDiscovered.map(\.element)) {
            displayElements[key] = element
        }

        let existing = order.filter { currentSet.contains($0) }
        let newKeys = currentKeys.filter { !order.contains($0) }
        order = newKeys + existing
        displayOrders[displayKey] = order

        return order.compactMap { displayElements[$0] }
    }

    private func windowKey(for window: AXUIElement) -> ManagedWindowKey {
        let identifier = AXBridge.identifier(of: window)
        let identity: String
        if let identifier, !identifier.isEmpty {
            // Ghostty currently publishes the same AXIdentifier
            // (TerminalWindowRestoration) for every terminal window. Include
            // the AX element identity for that duplicated identifier so
            // sibling windows remain separate logical entries.
            if identifier == "TerminalWindowRestoration" {
                identity = "ax:\(identifier):element:\(window.hashValue)"
            } else {
                identity = "ax:\(identifier)"
            }
        } else {
            // AXUIElement hash values distinguish sibling windows when an app
            // does not publish a stable identifier. Unlike title, this does
            // not change when a tab or document title changes.
            identity = "element:\(window.hashValue)"
        }
        return ManagedWindowKey(
            pid: AXBridge.pid(of: window),
            identity: identity,
            subrole: AXBridge.subrole(window) ?? ""
        )
    }

    private func displayIdentifier(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return String(number?.uint32Value ?? 0)
    }

    private func persistOrder(_ windows: [AXUIElement], for screen: NSScreen) {
        let displayKey = displayIdentifier(for: screen)
        let keys = windows.map { windowKey(for: $0) }
        displayOrders[displayKey] = keys
        for (key, window) in zip(keys, windows) {
            displayElements[key] = window
        }
    }

    @discardableResult
    private func applyTiles(_ windows: [AXUIElement], in frame: CGRect, config: Config) -> Bool {
        let tiled = windows.filter { !floatingWindows.contains($0) }
        guard !tiled.isEmpty else { return false }

        let tiles = LayoutEngine.computeTiles(
            for: tiled.count,
            in: frame,
            outerGap: config.outerGap,
            innerGap: config.innerGap,
            masterRatio: config.masterRatio
        )

        var changed = false
        for (i, window) in tiled.enumerated() where i < tiles.count {
            let tile = tiles[i]
            guard let current = AXBridge.frame(of: window) else { continue }
            let needsMove = abs(current.origin.x - tile.frame.origin.x) > 2
                || abs(current.origin.y - tile.frame.origin.y) > 2
            let needsResize = abs(current.width - tile.frame.width) > 2
                || abs(current.height - tile.frame.height) > 2

            if needsMove || needsResize {
                AXBridge.setFrame(window, to: tile.frame)
                changed = true
                if isDebugEnabled {
                    let after = AXBridge.frame(of: window)
                    print("[debug] applied: \(tile.frame) → actual \(String(describing: after))")
                    fflush(stdout)
                }
            }
        }
        return changed
    }

    private func focusedWindow() -> AXUIElement? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXBridge.appElement(pid: frontApp.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func allTiledOnCurrentDisplay() -> [AXUIElement] {
        guard let mainScreen = NSScreen.main else { return [] }
        let frame = LayoutEngine.visibleFrameInCG(for: mainScreen)
        return orderedWindows(on: frame, screen: mainScreen)
    }

    private func neighbors(of current: AXUIElement, direction: Int) -> [AXUIElement] {
        let all = allTiledOnCurrentDisplay()
        guard let currentIndex = all.firstIndex(of: current) else { return [] }

        var result: [AXUIElement] = []
        var idx = currentIndex + direction
        while idx >= 0 && idx < all.count {
            result.append(all[idx])
            idx += direction
        }
        return result
    }

    private func swapFocusedWindow(direction: Int) {
        guard let current = focusedWindow() else { return }
        let all = allTiledOnCurrentDisplay()
        guard let currentIndex = all.firstIndex(of: current) else { return }

        let targetIndex = currentIndex + direction
        guard targetIndex >= 0 && targetIndex < all.count else { return }

        let target = all[targetIndex]
        let currentFrame = AXBridge.frame(of: current)
        let targetFrame = AXBridge.frame(of: target)

        if let cf = currentFrame, let tf = targetFrame {
            AXBridge.setFrame(target, to: cf)
            AXBridge.setFrame(current, to: tf)
        }

        _ = AXUIElementPerformAction(current, kAXRaiseAction as CFString)
        tileAll()
    }
}