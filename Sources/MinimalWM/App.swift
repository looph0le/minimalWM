import Cocoa
import SwiftUI
import ApplicationServices

@main
struct MinimalWMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        Image(systemName: wm.isEnabled ? "rectangle.split.2x2.fill" : "rectangle.split.2x2")
            .symbolRenderingMode(.hierarchical)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let wm = WindowManager.shared
    private let eventObserver = EventObserver()
    private let configWatcher = ConfigWatcher()
    private var accessibilityTimer: Timer?
    private var servicesStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        wm.refreshAccessibilityStatus()
        if !AXBridge.requestAccessibility() {
            wm.refreshAccessibilityStatus()
            mwLog("minimalWM: Accessibility permission required. Grant in System Settings > Privacy & Security > Accessibility.")
            mwLog("PROMPT=1")
        }
        mwLog("minimalWM: launching pid=\(ProcessInfo.processInfo.processIdentifier)")

        NotificationCenter.default.addObserver(
            forName: EventObserver.windowChanged,
            object: nil,
            queue: .main
        ) { note in
            nonisolated(unsafe) let payload = note.object
            MainActor.assumeIsolated {
                if let event = payload as? WindowEvent {
                    WindowManager.shared.handleWindowEvent(event.name, element: event.element)
                } else {
                    WindowManager.shared.tileAllIfSpaceChanged()
                }
            }
        }

        // Apply config edits while the app runs, matching the documented
        // "changes apply immediately when saved" behavior.
        configWatcher.start()

        startServicesIfAuthorized()
        if !servicesStarted {
            accessibilityTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.startServicesIfAuthorized()
                if self.servicesStarted {
                    timer.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // User likely just returned from System Settings; refresh permission
        // state so the onboarding UI clears without a restart.
        wm.refreshAccessibilityStatus()
    }

    private func startServicesIfAuthorized() {
        guard !servicesStarted, AXIsProcessTrusted() else { return }
        servicesStarted = true
        mwLog("minimalWM: Accessibility granted")
        wm.accessibilityGranted = true
        wm.isEnabled = true
        wm.reloadFloatsFromConfig()
        wm.reloadHotkeys()
        eventObserver.start()

        let hk = HotkeyManager.shared
        hk.onAction = { [weak wm] action in
            guard let wm else { return }
            switch action {
            case .toggleTiling:
                wm.toggle()
            case .focusLeft:
                wm.focusLeft()
            case .focusRight:
                wm.focusRight()
            case .swapLeft:
                wm.swapLeft()
            case .swapRight:
                wm.swapRight()
            case .growMaster:
                wm.growMaster()
            case .shrinkMaster:
                wm.shrinkMaster()
            case .toggleFloat:
                wm.toggleFloat()
            }
        }
        hk.start()

        // Initial layout pass once the app settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak wm] in
            wm?.tileAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        configWatcher.stop()
        eventObserver.stop()
        HotkeyManager.shared.stop()
    }
}