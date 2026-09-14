import CoreGraphics
import Cocoa

struct LayoutEngine {

    struct Tile {
        let frame: CGRect
        let role: Role

        enum Role {
            case master
            case stack(index: Int)
        }
    }

    static func computeTiles(
        for windowCount: Int,
        in screenFrame: CGRect,
        outerGap: CGFloat,
        innerGap: CGFloat,
        masterRatio: CGFloat
    ) -> [Tile] {
        guard windowCount > 0 else { return [] }

        let gap = innerGap
        let outer = outerGap

        let availW = screenFrame.width - 2 * outer
        let availH = screenFrame.height - 2 * outer

        guard availW > 0 && availH > 0 else { return [] }

        if windowCount == 1 {
            return [Tile(frame: CGRect(
                x: screenFrame.origin.x + outer,
                y: screenFrame.origin.y + outer,
                width: availW,
                height: availH
            ), role: .master)]
        }

        let masterW = (availW - gap) * masterRatio
        let stackW = availW - masterW - gap
        let stackCount = windowCount - 1
        let stackSlotH = (availH - CGFloat(stackCount - 1) * gap) / CGFloat(stackCount)

        var tiles: [Tile] = []

        let masterFrame = CGRect(
            x: screenFrame.origin.x + outer,
            y: screenFrame.origin.y + outer,
            width: masterW,
            height: availH
        )
        tiles.append(Tile(frame: masterFrame, role: .master))

        let stackX = screenFrame.origin.x + outer + masterW + gap
        for i in 0..<stackCount {
            let y = screenFrame.origin.y + outer + CGFloat(i) * (stackSlotH + gap)
            tiles.append(Tile(frame: CGRect(
                x: stackX,
                y: y,
                width: stackW,
                height: stackSlotH
            ), role: .stack(index: i)))
        }

        return tiles
    }

    static func visibleFrameInCG(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let cocoaTop = visible.maxY
        let mainTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let cgY = mainTop - cocoaTop
        return CGRect(
            x: visible.origin.x,
            y: cgY,
            width: visible.width,
            height: visible.height
        )
    }
}