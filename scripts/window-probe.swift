// Prints on-screen window ids and bounds for a process id (used by smoke-test.sh).
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: window-probe <pid>\n", stderr)
    exit(2)
}
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("no window info\n", stderr)
    exit(1)
}
var found = 0
for window in raw {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    found += 1
    let number = window[kCGWindowNumber as String] ?? "?"
    let bounds = window[kCGWindowBounds as String] ?? "?"
    print("window=\(number) bounds=\(bounds)")
}
print("count=\(found)")
