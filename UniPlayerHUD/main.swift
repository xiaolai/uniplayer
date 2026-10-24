// UniPlayer HUD is a tiny alternate Finder handler. It has no windows of its
// own: it forwards the opened files to UniPlayer's URL scheme. Audio opens the
// compact HUD; video opens the standalone player window.
import AppKit
import UniformTypeIdentifiers

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
    var items = urls.map { URLQueryItem(name: "url", value: $0.absoluteString) }
    // The compact HUD is an audio presentation. Video keeps the full player
    // window, which is also where an ordinary Finder open lands.
    if urls.allSatisfy(isAudio) {
      items.append(URLQueryItem(name: "hud", value: "1"))
    }
    components.queryItems = items
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

  private func isAudio(_ url: URL) -> Bool {
    if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
      return type.conforms(to: .audio)
    }
    return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
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
