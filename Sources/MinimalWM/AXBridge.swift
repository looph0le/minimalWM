import ApplicationServices
import Cocoa

struct AXBridge {

    nonisolated(unsafe) static var lastDebugWindowDumpAt: CFAbsoluteTime = 0

    // Dumping every window on every tiledWindows() call floods the log and
    // starves the main run loop in debug builds. Cap topology dumps at 1/s.
    static func shouldLogWindowTopology() -> Bool {
        guard isDebugEnabled else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDebugWindowDumpAt >= 1.0 else { return false }
        lastDebugWindowDumpAt = now
        return true
    }

    static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        return false
    }

    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
    }

    static func appElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    // MARK: - Read

    static func windows(for pid: pid_t) -> [AXUIElement] {
        let app = appElement(pid: pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = position(of: element), let size = size(of: element) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func position(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let axVal = ref,
              CFGetTypeID(axVal) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axVal as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let axVal = ref,
              CFGetTypeID(axVal) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        return AXValueGetValue(axVal as! AXValue, .cgSize, &sz) ? sz : nil
    }

    static func title(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func identifier(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    static func isFullscreen(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    static func subrole(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    // MARK: - Write

    static func isEnhancedUIEnabled(pid: pid_t) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement(pid: pid),
            "AXEnhancedUserInterface" as CFString,
            &ref
        ) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    static func setEnhancedUI(pid: pid_t, enabled: Bool) {
        AXUIElementSetAttributeValue(
            appElement(pid: pid),
            "AXEnhancedUserInterface" as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    static func setFrame(
        _ element: AXUIElement,
        to rect: CGRect,
        writeSize: Bool = true,
        reinforcePosition: Bool = true,
        // The per-write enhanced UI round trip lets apps that are already in
        // enhanced mode accept geometry changes, but it is synchronous and can
        // block the run loop for 5–8 ms. Animations relax enhanced mode once
        // up front and pass false here to keep every intermediate write cheap.
        manageEnhancedUI: Bool = true
    ) {
        let needsEnhancedUIHandling = manageEnhancedUI && (writeSize || reinforcePosition)
        var wasEnhanced = false
        if needsEnhancedUIHandling {
            let app = appElement(pid: pid(of: element))
            var enhancedUI: CFTypeRef?
            wasEnhanced = AXUIElementCopyAttributeValue(
                app,
                "AXEnhancedUserInterface" as CFString,
                &enhancedUI
            ) == .success && (enhancedUI as? Bool) == true
            if wasEnhanced {
                AXUIElementSetAttributeValue(
                    app,
                    "AXEnhancedUserInterface" as CFString,
                    kCFBooleanFalse
                )
            }
        }

        if writeSize {
            // Apply bounds before position so the window is not briefly
            // resized around its old origin during a tile transition.
            setSize(element, to: rect.size)
        }
        setPosition(element, to: rect.origin)
        if reinforcePosition {
            setPosition(element, to: rect.origin)
        }

        if needsEnhancedUIHandling, wasEnhanced {
            let app = appElement(pid: pid(of: element))
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, to point: CGPoint) -> AXError {
        var p = point
        guard let val = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, to size: CGSize) -> AXError {
        var s = size
        guard let val = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
    }

    // MARK: - Collect all tiled windows on a display

    static func tiledWindows(on displayFrame: CGRect, floatApps: [String]) -> [(element: AXUIElement, app: String)] {
        var results: [(element: AXUIElement, app: String)] = []

        for app in runningApps() {
            let appName = app.localizedName ?? ""
            if floatApps.contains(appName) { continue }

            let windows = windows(for: app.processIdentifier)
            for window in windows {
                let isMin = isMinimized(window)
                let isFS = isFullscreen(window)
                let sub = subrole(window)
                let wf = frame(of: window)

                if shouldLogWindowTopology() {
                    let title = title(of: window) ?? ""
                    let identifier = identifier(of: window) ?? ""
                    print("[debug] \(appName): win=\(String(describing: wf)) subrole=\(String(describing: sub)) id=\(identifier) title=\(title) minimized=\(isMin) fullscreen=\(isFS)")
                    fflush(stdout)
                }

                guard !isMin, !isFS, sub == "AXStandardWindow" else { continue }
                guard let wf = frame(of: window) else { continue }
                guard wf.width > 100 && wf.height > 100 else { continue }
                guard displayFrame.contains(CGPoint(x: wf.midX, y: wf.midY)) else { continue }

                results.append((element: window, app: appName))
            }
        }

        return results.sorted {
            let left = frame(of: $0.element) ?? .zero
            let right = frame(of: $1.element) ?? .zero
            if abs(left.minY - right.minY) > 4 {
                return left.minY < right.minY
            }
            if abs(left.minX - right.minX) > 4 {
                return left.minX < right.minX
            }
            let leftPID = pid(of: $0.element)
            let rightPID = pid(of: $1.element)
            if leftPID != rightPID { return leftPID < rightPID }
            if $0.app != $1.app { return $0.app < $1.app }
            if abs(left.width - right.width) > 1 { return left.width < right.width }
            return left.height < right.height
        }
    }
}

let isDebugEnabled = CommandLine.arguments.contains("--debug")

func mwLog(_ message: String) {
    print(message)
    fflush(stdout)
}
