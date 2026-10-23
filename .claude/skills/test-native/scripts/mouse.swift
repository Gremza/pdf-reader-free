// Posts mouse events for UI tests (needs Accessibility permission for the terminal).
//   mouse click X Y            left-click
//   mouse right X Y            right-click
//   mouse drag X1 Y1 X2 Y2     left-drag, slow enough for SwiftUI drag & drop
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!.post(tap: .cghidEventTap)
}
let n = args.dropFirst().map { Double($0)! }
switch args.first {
case "click":
    let p = CGPoint(x: n[0], y: n[1])
    post(.leftMouseDown, p); usleep(80_000); post(.leftMouseUp, p)
case "right":
    let p = CGPoint(x: n[0], y: n[1])
    post(.rightMouseDown, p, .right); usleep(80_000); post(.rightMouseUp, p, .right)
case "drag":
    let from = CGPoint(x: n[0], y: n[1]), to = CGPoint(x: n[2], y: n[3])
    post(.mouseMoved, from); usleep(100_000)
    post(.leftMouseDown, from); usleep(300_000)
    for i in 1...30 {
        let f = Double(i) / 30
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f))
        usleep(30_000)
    }
    usleep(300_000); post(.leftMouseUp, to)
default:
    print("usage: mouse click X Y | mouse right X Y | mouse drag X1 Y1 X2 Y2")
}
