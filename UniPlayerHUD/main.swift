// UniPlayer HUD is a tiny alternate Finder handler. It has no windows of its
// own: it forwards the opened files to UniPlayer's URL scheme with `hud=1`,
// which opens the same media in the HUD (mini player) window.
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
  private var forwarded = false

  func application(_ application: NSApplication, open urls: [URL]) {
    forwarded = true
    guard !urls.isEmpty else {
      application.terminate(nil)
      return
    }
    var components = URLComponents()
    components.scheme = "uniplayer"
    components.host = "open"
    components.queryItems = urls.map { URLQueryItem(name: "url", value: $0.absoluteString) }
      + [URLQueryItem(name: "hud", value: "1")]
    guard let request = components.url else {
      NSLog("UniPlayer HUD: cannot build a uniplayer:// request")
      application.terminate(nil)
      return
    }
    if !NSWorkspace.shared.open(request) {
      NSLog("UniPlayer HUD: UniPlayer is not registered for uniplayer://")
    }
    application.terminate(nil)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Finder delivers files before this point. Launching the helper directly
    // should not leave an invisible process behind.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, !self.forwarded else { return }
      NSApp.terminate(nil)
    }
  }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
