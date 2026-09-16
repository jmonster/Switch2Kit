// A CI-only observer: no screenshots, window titles, Accessibility, or input injection.
import AppKit
import CoreGraphics
import Foundation

@MainActor
func observe() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let pid = Int32(args[2]), pid > 1,
          args[1] == "inspect" || args[1] == "quit" else {
        throw NSError(domain: "LaunchObserver", code: 1)
    }
    let expected = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
    guard let app = NSRunningApplication(processIdentifier: pid),
          app.executableURL?.resolvingSymlinksInPath() == expected else {
        print("{\"matched\":false}")
        return
    }
    var result: [String: Any] = ["matched": true, "finished": app.isFinishedLaunching]
    if args[1] == "quit" {
        // This is a request, not proof of termination. The parent waits for exit.
        result["quit_requested"] = app.terminate()
    } else {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw NSError(domain: "LaunchObserver", code: 2)
        }
        result["windows"] = windows.filter { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else { return false }
            return width.doubleValue >= 100 && height.doubleValue >= 100
        }.count
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

do { try observe() } catch {
    FileHandle.standardError.write(Data("Application observation failed.\n".utf8))
    exit(1)
}
