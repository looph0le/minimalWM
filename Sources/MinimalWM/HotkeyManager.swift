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
    var display: String

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
    private(set) var hotkeys: [Hotkey] = []

    var onAction: ((Hotkey.Action) -> Void)?

    private init() {}

    func start() {
        guard eventTap == nil else { return }

        hotkeys = buildHotkeys(from: Config.load())

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

    // Rebuilds the active hotkey set from the current config so menu help and
    // the event tap always agree with ~/.config/minimalWM/config.json.
    func rebuildFromConfig() {
        let built = buildHotkeys(from: Config.load())
        if built != hotkeys {
            hotkeys = built
        }
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

    // MARK: - Event tap

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

    // MARK: - Configuration

    private func buildHotkeys(from config: Config) -> [Hotkey] {
        var result: [Hotkey] = []
        let entries: [((Config) -> String, String, Hotkey.Action)] = [
            ({ $0.toggleKey }, "Toggle Tiling", .toggleTiling),
            ({ $0.focusLeftKey }, "Focus Left", .focusLeft),
            ({ $0.focusRightKey }, "Focus Right", .focusRight),
            ({ $0.swapLeftKey }, "Swap Left", .swapLeft),
            ({ $0.swapRightKey }, "Swap Right", .swapRight),
            ({ $0.growMasterKey }, "Grow Master", .growMaster),
            ({ $0.shrinkMasterKey }, "Shrink Master", .shrinkMaster),
            ({ $0.toggleFloatKey }, "Toggle Float", .toggleFloat),
        ]
        for (combo, name, action) in entries {
            guard let parsed = Self.parseCombo(combo(config)) else { continue }
            result.append(Hotkey(
                name: name,
                keyCode: parsed.keyCode,
                modifiers: parsed.modifiers,
                action: action,
                display: parsed.display
            ))
        }
        return result
    }

    struct ParsedCombo {
        let keyCode: UInt16
        let modifiers: CGEventFlags
        let display: String
    }

    static func parseCombo(_ raw: String) -> ParsedCombo? {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyPart = parts.last, !parts.isEmpty else { return nil }

        var flags: CGEventFlags = []
        var symbols: [String] = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command":
                flags.insert(.maskCommand)
                symbols.append("⌘")
            case "ctrl", "control":
                flags.insert(.maskControl)
                symbols.append("⌃")
            case "alt", "option", "opt":
                flags.insert(.maskAlternate)
                symbols.append("⌥")
            case "shift":
                flags.insert(.maskShift)
                symbols.append("⇧")
            default:
                return nil
            }
        }

        guard let keyCode = keyCode(for: keyPart) else { return nil }
        return ParsedCombo(
            keyCode: keyCode,
            modifiers: flags,
            display: symbols.joined() + keySymbol(for: keyPart)
        )
    }

    private static func keyCode(for key: String) -> UInt16? {
        if key == "space" {
            return UInt16(kVK_Space)
        }
        if key.count == 1, let ascii = key.lowercased().unicodeScalars.first?.value {
            if ascii >= 97 && ascii <= 122 {
                return UInt16(Int(kVK_ANSI_A) + Int(ascii - 97))
            }
            if ascii >= 48 && ascii <= 57 {
                return UInt16(Int(kVK_ANSI_0) + Int(ascii - 48))
            }
        }
        return nil
    }

    private static func keySymbol(for key: String) -> String {
        key == "space" ? "Space" : key.uppercased()
    }
}