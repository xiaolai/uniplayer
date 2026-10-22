//
//  InlinePlayerView.swift
//  uniplayer
//
//  The AppKit side of inline playback: one long-lived host that owns the
//  library's copy of the player surface, and a thin SwiftUI wrapper that only
//  reparents that host. The host is created once by the library window and
//  never recreated, which is what keeps `VideoView` stable across pane
//  changes and file switches.
//

import AppKit
import SwiftUI

/// A container that borrows the player surface.
///
/// Clicking it makes the surface the first responder, reports activity to the
/// controls overlay, and turns a double-click into fullscreen. It deliberately
/// does not create a player: `PlayerCore` owns the only `VideoView`.
final class InlinePlayerSurfaceHost: NSView, PlayerSurfaceHosting {

  var surfaceContainer: NSView { self }

  /// Called on hover, pointer movement, clicks and scrolls.
  var onActivity: (() -> Void)?
  /// Called for a double-click on the video.
  var onDoubleClick: (() -> Void)?

  private var tracking: NSTrackingArea?

  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.acceptsMouseMovedEvents = true
    // The display link must follow the window that now owns the surface, not
    // the hidden player window it came from.
    (subviews.first as? VideoView)?.updateDisplayLink()
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    (subview as? VideoView)?.updateDisplayLink()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking {
      removeTrackingArea(tracking)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onActivity?()
  }

  override func mouseUp(with event: NSEvent) {
    handleSurfaceEvent(event)
  }

  override func rightMouseDown(with event: NSEvent) {
    onActivity?()
  }

  override func mouseMoved(with event: NSEvent) {
    onActivity?()
  }

  override func mouseEntered(with event: NSEvent) {
    onActivity?()
  }

  func handleSurfaceEvent(_ event: NSEvent) {
    onActivity?()
    // Only a double left-click toggles fullscreen; the player window forwards
    // right-button events through the same entry point.
    if event.type == .leftMouseUp, event.clickCount == 2 {
      onDoubleClick?()
    }
  }
}

/// The SwiftUI bridge. `makeNSView` builds a throwaway wrapper; the host it
/// attaches is the stable object.
struct InlinePlayerView: NSViewRepresentable {
  let host: InlinePlayerSurfaceHost

  func makeNSView(context: Context) -> InlinePlayerWrapperView {
    InlinePlayerWrapperView(host: host)
  }

  func updateNSView(_ nsView: InlinePlayerWrapperView, context: Context) {
    nsView.attachHost()
  }

  static func dismantleNSView(_ nsView: InlinePlayerWrapperView, coordinator: ()) {
    nsView.detachHost()
  }
}

final class InlinePlayerWrapperView: NSView {
  private let host: InlinePlayerSurfaceHost

  init(host: InlinePlayerSurfaceHost) {
    self.host = host
    super.init(frame: .zero)
    attachHost()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func attachHost() {
    guard host.superview !== self else { return }
    host.removeFromSuperview()
    host.translatesAutoresizingMaskIntoConstraints = false
    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func detachHost() {
    if host.superview === self {
      host.removeFromSuperview()
    }
  }
}
