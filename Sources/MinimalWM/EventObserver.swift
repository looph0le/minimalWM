import ApplicationServices
import Cocoa

// Only ever observed on the main thread (run-loop observer + main queue).
struct WindowEvent: @unchecked Sendable {
    let name: String
    let element: AXUIElement
}

final class EventObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private var observedPIDs: Set<pid_t> = []

    static let windowChanged = Notification.Name("minimalWM.windowEvent")

    private var debounceTimer: Timer?
    private var topologyTimer: Timer?
    private var windowCounts: [pid_t: Int] = [:]
    private var workspaceObserverTokens: [NSObjectProtocol] = []

    // MARK: - Start / Stop

    func start() {
        observeAllApps()
        refreshWindowCounts()
        topologyTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkWindowTopology()
        }
        if let topologyTimer {
            RunLoop.main.add(topologyTimer, forMode: .common)
        }
        observeWorkspaceChanges()
    }

    func stop() {
        for pid in observers.keys {
            removeObserver(for: pid)
        }
        observers.removeAll()
        observedPIDs.removeAll()
        debounceTimer?.invalidate()
        topologyTimer?.invalidate()
        windowCounts.removeAll()
        for token in workspaceObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()
    }

    // MARK: - App observation

    func observeAllApps() {
        for app in AXBridge.runningApps() {
            observe(app)
        }
    }

    private func refreshWindowCounts() {
        windowCounts = Dictionary(
            uniqueKeysWithValues: AXBridge.runningApps().map { app in
                (app.processIdentifier, AXBridge.windows(for: app.processIdentifier).count)
            }
        )
    }

    private func checkWindowTopology() {
        let currentCounts = Dictionary(
            uniqueKeysWithValues: AXBridge.runningApps().map { app in
                (app.processIdentifier, AXBridge.windows(for: app.processIdentifier).count)
            }
        )
        guard currentCounts != windowCounts else { return }

        windowCounts = currentCounts
        post(debounce: 0.05)
    }

    func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observedPIDs.insert(pid).inserted else { return }

        let callback: AXObserverCallback = { _, element, notification, _ in
            let event = WindowEvent(
                name: (notification as String),
                element: element
            )
            NotificationCenter.default.post(
                name: Notification.Name("minimalWM.windowEvent"),
                object: event
            )
        }

        var observer: AXObserver?
        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let observer else {
            observedPIDs.remove(pid)
            return
        }

        let appElement = AXBridge.appElement(pid: pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)

        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]

        for n in notifications {
            AXObserverAddNotification(observer, appElement, n as CFString, nil)
        }

        // Register window-level notifications on each existing window too.
        // Some apps deliver moved/resized only on the window element.
        for window in AXBridge.windows(for: pid) {
            for n in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverAddNotification(observer, window, n as CFString, nil)
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        observers[pid] = observer
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observedPIDs.remove(pid)
    }

    // MARK: - Workspace / space changes

    private func observeWorkspaceChanges() {
        let ws = NSWorkspace.shared.notificationCenter

        workspaceObserverTokens.append(ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.observe(app)
            }
            self.post(debounce: 0.05)
        })

        workspaceObserverTokens.append(ws.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.post(debounce: 0.05)
        })

        workspaceObserverTokens.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.post()
        })

        workspaceObserverTokens.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.post(debounce: 0.1)
        })

        workspaceObserverTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.post(debounce: 0.1)
        })
    }

    private func post(debounce: TimeInterval = 0) {
        if debounce > 0 {
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { _ in
                NotificationCenter.default.post(name: Self.windowChanged, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: Self.windowChanged, object: nil)
        }
    }
}
