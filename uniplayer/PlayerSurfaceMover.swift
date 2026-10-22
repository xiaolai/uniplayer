//
//  PlayerSurfaceMover.swift
//  uniplayer
//
//  The one player surface — `VideoView` — is owned by `PlayerCore` and borrowed
//  by whichever host is presenting playback: the player window, the mini
//  player, or the library's inline detail. This type is the only place that
//  reparents it, so a new host cannot invent its own move rules and leave the
//  surface in a different state.
//

import AppKit

/// Moves one existing view between hosts without recreating it.
///
/// `attach` is the inline/mini entry point and fills the destination.
/// `restore` is the player-window entry point and activates the window's own
/// constraints, which the window keeps so it can adjust their constants.
final class PlayerSurfaceMover {
  private weak var surface: NSView?

  init(surface: NSView) {
    self.surface = surface
  }

  /// Attaches the surface to `container`, pinned to all four edges.
  ///
  /// - Returns: `true` when the surface moved; `false` when it was already in
  ///   `container` or the surface has gone away.
  @discardableResult
  func attach(to container: NSView, positioned: NSWindow.OrderingMode = .above,
              relativeTo sibling: NSView? = nil) -> Bool {
    guard let surface else { return false }
    if surface.superview === container { return false }

    surface.removeFromSuperview()
    surface.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(surface, positioned: positioned, relativeTo: sibling)
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      surface.topAnchor.constraint(equalTo: container.topAnchor),
      surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return true
  }

  /// Puts the surface back into the player window and activates the window's
  /// constraints. Constraints belonging to the previous host are discarded by
  /// AppKit when the surface leaves that host.
  func restore(to container: NSView, constraints: [NSLayoutConstraint]) {
    guard let surface else { return }

    surface.removeFromSuperview()
    surface.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(surface)
    NSLayoutConstraint.activate(constraints)
  }
}
