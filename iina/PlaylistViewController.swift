//
//  PlaylistViewController.swift
//  iina
//
//  Created by lhc on 17/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

extension SidebarViewController.TabType {
  static let playlist = SidebarViewController.TabType(0, "playlist", .sf("music.note.list")!)
  static let chapters = SidebarViewController.TabType(1, "chapters", .sf("list.and.film")!)
}


class PlaylistViewController: SidebarViewController {
  var isInMiniPlayer: Bool = false

  override var sidebarType: SidebarController.ViewType {
    .playlist
  }
  override var leadingPrefKey: Preference.Key {
    .sidebarPlaylistDisplayAtLeading
  }

  override func allTabs() -> [SidebarViewController.TabType] {
    [.playlist, .chapters]
  }
  override var defaultTab: SidebarViewController.TabType {
    .playlist
  }

  override func getTabView(for tab: SidebarViewController.TabType) -> SidebarPane {
    return switch tab {
    case .playlist: SidebarPlaylistPane(player: player)
    case .chapters: SidebarChaptersPane(player: player)
    default: fatalError()
    }
  }

  @IBAction func prefixBtnAction(_ sender: PlaylistPrefixButton) {
    sender.isFolded = !sender.isFolded
  }

}

