import ApplicationServices
import Carbon.HIToolbox
import Cocoa

struct Hotkey: Equatable {
    enum Action: String {
        case toggleTiling = "toggle"
        case focusLeft = "focus_left"
        case focusRight = "focus_right"
        case swapLeft = "swap_left"
        case swapRight = "swap_right"
        case growMaster = "grow_master"
        case shrinkMaster = "shrink_master"
        case toggleFloat = "float"
    }

    let name: String
    let keyCode: UInt16
    let modifiers: CGEventFlags
    let action: Action

    func matches(_ code: UInt16, _ flags: CGEventFlags) -> Bool {
        keyCode == code && modifiers == flags
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<HotkeyManager>?

    var onAction: ((Hotkey.Action) -> Void)?
    private var hotkeys: [Hotkey] = []

    private init() {}

    func start() {
        guard eventTap == nil else { return }

        hotkeys = buildHotkeys()

        let eventMask = CGEventMask((1 << CGEventType.keyDown.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                .handleEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            print("minimalWM: failed to create event tap (check Accessibility permission)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        for hotkey in hotkeys where hotkey.matches(keyCode, flags) {
            onAction?(hotkey.action)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func buildHotkeys() -> [Hotkey] {

        let cmdCtrl: CGEventFlags = [.maskCommand, .maskControl]

        return [
            Hotkey(name: "Toggle Tiling", keyCode: UInt16(kVK_Space), modifiers: cmdCtrl, action: .toggleTiling),
            Hotkey(name: "Focus Left", keyCode: UInt16(kVK_ANSI_H), modifiers: cmdCtrl, action: .focusLeft),
            Hotkey(name: "Focus Right", keyCode: UInt16(kVK_ANSI_L), modifiers: cmdCtrl, action: .focusRight),
            Hotkey(name: "Swap Left", keyCode: UInt16(kVK_ANSI_H), modifiers: cmdCtrl.union(.maskShift), action: .swapLeft),
            Hotkey(name: "Swap Right", keyCode: UInt16(kVK_ANSI_L), modifiers: cmdCtrl.union(.maskShift), action: .swapRight),
            Hotkey(name: "Grow Master", keyCode: UInt16(kVK_ANSI_J), modifiers: cmdCtrl, action: .growMaster),
            Hotkey(name: "Shrink Master", keyCode: UInt16(kVK_ANSI_K), modifiers: cmdCtrl, action: .shrinkMaster),
            Hotkey(name: "Toggle Float", keyCode: UInt16(kVK_ANSI_F), modifiers: cmdCtrl, action: .toggleFloat),
        ]
    }
}