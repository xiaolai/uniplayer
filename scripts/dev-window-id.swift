// Prints the number of the largest on-screen, layer-zero window owned by the
// given process. Used by dev-ui.sh to capture the development app's window
// without Accessibility or Screen Recording prompts.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
  FileHandle.standardError.write(Data("usage: dev-window-id <pid>\n".utf8))
  exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best = (number: 0, area: CGFloat.zero)
for window in windows {
  guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
        (window[kCGWindowLayer as String] as? Int) == 0,
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let width = bounds["Width"], let height = bounds["Height"] else { continue }
  let area = width * height
  if area > best.area { best = (number, area) }
}
guard best.number != 0 else {
  FileHandle.standardError.write(Data("no on-screen window for pid \(pid)\n".utf8))
  exit(1)
}
print(best.number)
