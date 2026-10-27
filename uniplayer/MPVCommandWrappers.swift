//
//  MPVCommandWrappers.swift
//  uniplayer
//
//  Created by Yuze Jiang on 2025/05/25.
//  Copyright © 2025 lhc. All rights reserved.
//

extension MPVController {
  func playlistInsert(_ path: String, index: Int) {
    command(.loadfile, args: [path, "insert-at", index.description], level: .verbose)
  }

  func playlistAppend(_ path: String, options: String? = nil) {
    var args = [path, "append"]
    if let options {
      args += ["0", options]
    }
    command(.loadfile, args: args, level: .verbose)
  }

  /// Appends a playlist tail entry while preserving its file-local options.
  /// Cloud-drive entries need the node form for their HTTP headers.
  func playlistAppend(_ path: String, plan: PlaybackLoadPlan?) {
    if PlaybackEngineOptions.requiresNodeLoad(plan) {
      loadfileNode(path: path, plan: plan, flags: "append", index: -1)
    } else {
      playlistAppend(path, options: PlaybackEngineOptions.loadfileOptions(for: plan))
    }
  }

  func playlistMove(_ from: Int, to: Int) {
    command(.playlistMove, args: ["\(from)", "\(to)"], level: .verbose)
  }

  func playlistRemove(_ index: Int) {
    command(.playlistRemove, args: [index.description], level: .verbose)
  }

}
