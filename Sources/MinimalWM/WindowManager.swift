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
    private var lastMoveTime = CFAbsoluteTime(0)
    private var quietTimer: Timer?
    private var dragOrder: [AXUIElement] = []
    private var dragOriginalOrder: [AXUIElement] = []
    private var dragDisplayFrame: CGRect?
    private var dragPreviewIndex: Int?
    private var dragHasValidDrop = false
    private var frameAnimationTimer: Timer?
    private var animationStates: [AXUIElement: WindowAnimationState] = [:]
    private var animationWindows: Set<AXUIElement> = []
    private let dragConfirmInterval: TimeInterval = 0.25
    private let dragQuietInterval: TimeInterval = 0.3
    private let dragAnimationDuration: TimeInterval = 0.14
    private let frameAnimationInterval: TimeInterval = 1.0 / 120.0
    private let dragHysteresis: CGFloat = 24

    private struct WindowAnimationState {
        var frame: CGRect
        var lastWrittenFrame: CGRect
        var velocity: CGVector
        var sizeVelocity: CGSize
        var target: CGRect
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
            let windows = AXBridge.tiledWindows(on: frame, floatApps: config.floatApps)
                .filter { AXBridge.pid(of: $0.element) != ProcessInfo.processInfo.processIdentifier }

            guard gen == tileGeneration else { return }

            let elements = windows.map(\.element)
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

        // Ignore movement notifications only for windows currently written by
        // the animation loop. A time-based global suppression can swallow the
        // first real drag event after a layout settles.
        if frameAnimationTimer != nil, animationWindows.contains(window) {
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
        let windows = AXBridge.tiledWindows(on: displayFrame, floatApps: config.floatApps)
            .map(\.element)
            .filter {
                AXBridge.pid(of: $0) != ProcessInfo.processInfo.processIdentifier
                    && !floatingWindows.contains($0)
            }

        dragOrder = windows
        dragOriginalOrder = windows
        dragDisplayFrame = displayFrame
        dragPreviewIndex = windows.firstIndex(of: dragged)
        dragHasValidDrop = false
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
            let sourceWindows = AXBridge.tiledWindows(
                on: previousFrame,
                floatApps: config.floatApps
            )
            .map(\.element)
            .filter {
                AXBridge.pid(of: $0) != ProcessInfo.processInfo.processIdentifier
                    && !floatingWindows.contains($0)
                    && $0 != dragged
            }
            animateTiles(sourceWindows, in: previousFrame, duration: dragAnimationDuration)

            dragOrder = AXBridge.tiledWindows(on: frame, floatApps: config.floatApps)
                .map(\.element)
                .filter {
                    AXBridge.pid(of: $0) != ProcessInfo.processInfo.processIdentifier
                        && !floatingWindows.contains($0)
                }
            dragOriginalOrder = dragOrder
            dragPreviewIndex = dragOrder.firstIndex(of: dragged)
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
            return
        }
        dragHasValidDrop = true
        guard targetIndex != currentIndex else { return }

        var reordered = dragOrder
        reordered.remove(at: currentIndex)
        reordered.insert(dragged, at: min(targetIndex, reordered.count))
        dragOrder = reordered
        dragPreviewIndex = targetIndex
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
        dragWindow = nil
        dragOrder = []
        dragOriginalOrder = []
        dragDisplayFrame = nil
        dragPreviewIndex = nil
        dragHasValidDrop = false
    }

    private func stopAnimations() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        animationStates.removeAll()
        animationWindows.removeAll()
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

        // Still receiving moves — keep waiting for the drop.
        if now - lastMoveTime < 0.05 {
            scheduleQuietCheck(interval: 0.1)
            return
        }

        handleDrop(of: dragged)
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

        var tiled = AXBridge.tiledWindows(on: frame, floatApps: config.floatApps)
            .map { $0.element }
            .filter {
                AXBridge.pid(of: $0) != ProcessInfo.processInfo.processIdentifier
                    && !floatingWindows.contains($0)
            }

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

        let animationTimer = Timer(timeInterval: frameAnimationInterval, repeats: true) {
            [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let dt = min(self.frameAnimationInterval, 0.033)
            let stiffness: CGFloat = 720
            let damping: CGFloat = 42
            var settled = true

            for (window, var state) in self.animationStates {
                let dx = state.target.origin.x - state.frame.origin.x
                let dy = state.target.origin.y - state.frame.origin.y
                let dw = state.target.width - state.frame.width
                let dh = state.target.height - state.frame.height

                state.velocity.dx += (stiffness * dx - damping * state.velocity.dx) * dt
                state.velocity.dy += (stiffness * dy - damping * state.velocity.dy) * dt
                state.frame.origin.x += state.velocity.dx * dt
                state.frame.origin.y += state.velocity.dy * dt

                state.sizeVelocity.width += (stiffness * dw - damping * state.sizeVelocity.width) * dt
                state.sizeVelocity.height += (stiffness * dh - damping * state.sizeVelocity.height) * dt
                state.frame.size.width += state.sizeVelocity.width * dt
                state.frame.size.height += state.sizeVelocity.height * dt

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
                if writeDelta > 1 {
                    AXBridge.setFrame(window, to: state.frame)
                    state.lastWrittenFrame = state.frame
                }
                self.animationStates[window] = state
            }

            if settled {
                timer.invalidate()
                self.frameAnimationTimer = nil
                self.animationStates.removeAll()
                self.animationWindows.removeAll()
            }
        }
        frameAnimationTimer = animationTimer
        RunLoop.main.add(animationTimer, forMode: .common)
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
        return AXBridge.tiledWindows(on: frame, floatApps: config.floatApps)
            .map { $0.element }
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