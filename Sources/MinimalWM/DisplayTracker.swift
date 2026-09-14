import CoreGraphics
import Cocoa

enum DisplayTracker {

    static func currentDisplays() -> [CGScreen] {
        NSScreen.screens
    }
}

typealias CGScreen = NSScreen

struct DisplayInfo {
    let id: CGDirectDisplayID
    let frame: CGRect
    let visibleFrameCGRect: CGRect
}

func displayInfo(for screen: NSScreen) -> DisplayInfo {
    let id = CGDirectDisplayID((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int) ?? 0)
    return DisplayInfo(
        id: id,
        frame: screen.frame,
        visibleFrameCGRect: LayoutEngine.visibleFrameInCG(for: screen)
    )
}