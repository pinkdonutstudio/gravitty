import AppKit

// Invisible strip along an edge or corner of the expanded panel (the top edge is attached to the screen and is not
// resizable). Reports the drag as a total offset from where it started, in screen points (y up, so dragging down
// gives a negative dy). The panel stays centered under the notch, so a width change is twice the horizontal drag.
final class ResizeHandle: NSView {
    enum Edge {
        case bottom, left, right, bottomLeft, bottomRight

        func newSize(from s: NSSize, dx: CGFloat, dy: CGFloat) -> NSSize {
            switch self {
            case .bottom: return NSSize(width: s.width, height: s.height - dy)
            case .left: return NSSize(width: s.width - 2 * dx, height: s.height)
            case .right: return NSSize(width: s.width + 2 * dx, height: s.height)
            case .bottomLeft: return NSSize(width: s.width - 2 * dx, height: s.height - dy)
            case .bottomRight: return NSSize(width: s.width + 2 * dx, height: s.height - dy)
            }
        }

        var cursor: NSCursor {
            switch self {
            case .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            case .bottomLeft, .bottomRight:
                if #available(macOS 15, *) { return .frameResize(position: self == .bottomLeft ? .bottomLeft : .bottomRight, directions: .all) }
                return .crosshair // shortcut: macOS 14 has no public diagonal resize cursor
            }
        }
    }

    let edge: Edge
    var onBegin: (() -> Void)?, onDrag: ((CGFloat, CGFloat) -> Void)?, onEnd: (() -> Void)?
    private var start = NSPoint.zero

    init(_ edge: Edge) { self.edge = edge; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: edge.cursor) }
    override func mouseDown(with e: NSEvent) { start = NSEvent.mouseLocation; onBegin?() }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        onDrag?(p.x - start.x, p.y - start.y)
    }
    override func mouseUp(with e: NSEvent) { onEnd?() }
}
