//
//  MainWindowMenuActions.swift
//  uniplayer
//
//  Created by lhc on 25/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa


class MainMenuActionHandler: NSResponder, NSMenuItemValidation {

  unowned var player: PlayerCore

  init(playerCore: PlayerCore) {
    self.player = playerCore
    super.init()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc func menuToggleAssistant(_ sender: Any?) {
    player.initialWindow.showWindow(nil)
    DispatchQueue.main.async { self.player.initialWindow.menuToggleInspector(sender) }
  }
  @objc func menuSearchLibrary(_ sender: Any?) {
    player.initialWindow.showWindow(nil)
    DispatchQueue.main.async { self.player.initialWindow.menuSearchLibrary(sender) }
  }
  @objc func menuToggleLibraryFocus(_ sender: Any?) { player.initialWindow.menuToggleFocusMode(sender) }

  @objc func menuShowInspector(_ sender: AnyObject) {
    let inspector = AppDelegate.shared.inspector
    inspector.showWindow(self)
  }

  @objc func menuSavePlaylist(_ sender: NSMenuItem) {
    Utility.quickSavePanel(title: "Save to playlist", types: ["m3u8"], sheetWindow: player.currentWindow) { (url) in
      if url.isFileURL {
        var playlist = ""
        self.player.info.$playlist.withLock {
          for item in $0 {
            playlist.append((item.filename + "\n"))
          }
        }
        do {
          try playlist.write(to: url, atomically: true, encoding: String.Encoding.utf8)
        } catch let error as NSError {
          Utility.showAlert("error_saving_file", arguments: ["playlist",
                                                            error.localizedDescription])
        }
      }
    }
  }

  @objc func menuShowCurrentFileInFinder(_ sender: NSMenuItem) {
    guard let url = player.info.currentURL, !player.info.isNetworkResource else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc func menuDeleteCurrentFile(_ sender: NSMenuItem) {
    guard let url = player.info.currentURL, !player.info.isNetworkResource else { return }
    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    } catch let error {
      Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
      return
    }
    let index = player.mpv.getInt(MPVProperty.playlistPos)
    player.playlistRemove(index)
  }

  // currently only being used for key command
  @objc func menuDeleteCurrentFileHard(_ sender: NSMenuItem) {
    guard let url = player.info.currentURL, !player.info.isNetworkResource else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error {
      Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
      return
    }
    let index = player.mpv.getInt(MPVProperty.playlistPos)
    player.playlistRemove(index)
  }

  /// Returns playback from the detached player window to the library detail.
  @objc func menuReturnToInline(_ sender: NSMenuItem) {
    guard !player.isInline, player.info.state.active else { return }
    player.initialWindow.showWindow(nil)
    DispatchQueue.main.async {
      self.player.presentInline(in: self.player.initialWindow.inlineHost)
      self.player.initialWindow.window?.makeKeyAndOrderFront(nil)
    }
  }

}

// MARK: - Control

extension MainMenuActionHandler {
  @objc func menuTogglePause(_ sender: NSMenuItem) {
    player.togglePause()
    // set speed to 0 if is fastforwarding
    if player.mainWindow.isFastforwarding {
      player.setSpeed(1)
      player.mainWindow.isFastforwarding = false
    }
  }

  @objc func menuStop(_ sender: NSMenuItem) {
    // FIXME: handle stop
    player.sendOSD(.stop)
    player.stop()
  }

  @objc func menuStep(_ sender: NSMenuItem) {
    if let args = sender.representedObject as? (Double, Preference.SeekOption) {
      player.seek(relativeSecond: args.0, option: args.1)
    } else if let value = sender.representedObject as? Double {
      player.seek(relativeSecond: value, option: Preference.SeekOption.defaultValue)
    } else {
      let seconds = Double(abs((sender.representedObject as? Int) ?? 5))
      if sender.tag == 0 { // -> 5s
        player.seek(relativeSecond: seconds, option: Preference.SeekOption.defaultValue)
      } else if sender.tag == 1 { // <- 5s
        player.seek(relativeSecond: -seconds, option: Preference.SeekOption.defaultValue)
      }
    }
  }

  @objc func menuStepFrame(_ sender: NSMenuItem) {
    if player.info.state == .playing {
      player.pause()
    }
    if sender.tag == 0 { // -> 1f
      player.frameStep(backwards: false)
    } else if sender.tag == 1 { // <- 1f
      player.frameStep(backwards: true)
    }
  }

  @objc func menuChangeSpeed(_ sender: NSMenuItem) {
    if sender.tag == 5 {
      player.setSpeed(1)
      return
    }
    if let multiplier = sender.representedObject as? Double {
      player.setSpeed(player.info.playSpeed * multiplier)
    }
  }

  @objc func menuJumpToBegin(_ sender: NSMenuItem) {
    player.seek(absoluteSecond: 0)
  }

  @objc func menuJumpTo(_ sender: NSMenuItem) {
    // Make certain the cached video position in the playback info is up to date.
    player.syncPositionIfNeeded()
    Utility.quickPromptPanel("jump_to", inputValue: self.player.info.videoPosition?.stringRepresentationWithPrecision(3)) { input in
      if let vt = VideoTime(input) {
        self.player.seek(absoluteSecond: vt.second)
      }
    }
  }

  @objc func menuSnapshot(_ sender: NSMenuItem) {
    player.screenshot()
  }

  @objc func menuABLoop(_ sender: NSMenuItem) {
    player.mainWindow.abLoop()
  }

  @objc func menuFileLoop(_ sender: NSMenuItem) {
    player.toggleFileLoop()
  }

  @objc func menuPlaylistLoop(_ sender: NSMenuItem) {
    player.togglePlaylistLoop()
  }

  @objc func menuPlaylistItem(_ sender: NSMenuItem) {
    let index = sender.tag
    player.playFileInPlaylist(index)
  }

  @objc func menuChapterSwitch(_ sender: NSMenuItem) {
    let index = sender.tag
    guard let chapter = player.playChapter(index) else {
      Logger.log("Cannot switch to chapter \(index) because it was not found! Will ignore request and reload chapters instead",
                 subsystem: player.subsystem)
      player.getChapters()
      return
    }
    player.sendOSD(.chapter(chapter.title))
  }

  @objc func menuChangeTrack(_ sender: NSMenuItem) {
    if let trackObj = sender.representedObject as? (MPVTrack, MPVTrack.TrackType) {
      player.setTrack(trackObj.0.id, forType: trackObj.1)
    } else if let trackObj = sender.representedObject as? MPVTrack {
      player.setTrack(trackObj.id, forType: trackObj.type)
    }
  }

  @objc func menuNextMedia(_ sender: NSMenuItem) {
    player.navigateInPlaylist(nextMedia: true)
  }

  @objc func menuPreviousMedia(_ sender: NSMenuItem) {
    player.navigateInPlaylist(nextMedia: false)
  }

  @objc func menuNextChapter(_ sender: NSMenuItem) {
    player.mpv.command(.add, args: ["chapter", "1"], checkError: false)
  }

  @objc func menuPreviousChapter(_ sender: NSMenuItem) {
    player.mpv.command(.add, args: ["chapter", "-1"], checkError: false)
  }
}

// MARK: - Video

extension MainMenuActionHandler {
  @objc func menuChangeAspect(_ sender: NSMenuItem) {
    if let aspectStr = sender.representedObject as? String {
      player.setVideoAspect(aspectStr)
      player.sendOSD(.aspect(aspectStr))
    } else {
      Logger.log("Unknown aspect in menuChangeAspect(): \(sender.representedObject.debugDescription)", level: .error)
    }
  }

  @objc func menuChangeCrop(_ sender: NSMenuItem) {
    if let cropStr = sender.representedObject as? String {
      if cropStr == "Custom" {
        if player.isInline {
          // The crop controls live in the player window; bring it back first
          // instead of entering an interactive mode whose controls are hidden.
          player.endInlinePresentation(showWindow: true)
        }
        player.mainWindow.sidebars.hideAllSideBars {
          self.player.mainWindow.interactiveMode
            .enter(mode: .crop, selectWholeVideoByDefault: true)
        }
        return
      }
      player.setCrop(fromString: cropStr)
    } else {
      Logger.log("sender.representedObject is not a string in menuChangeCrop()", level: .error)
    }
  }

  @objc func menuChangeRotation(_ sender: NSMenuItem) {
    if let rotationInt = sender.representedObject as? Int {
      player.setVideoRotate(rotationInt)
    }
  }

  @objc func menuToggleFlip(_ sender: NSMenuItem) {
    if player.info.flipFilter == nil {
      player.setFlip(true)
    } else {
      player.setFlip(false)
    }
  }

  @objc func menuToggleMirror(_ sender: NSMenuItem) {
    if player.info.mirrorFilter == nil {
      player.setMirror(true)
    } else {
      player.setMirror(false)
    }
  }

  @objc func menuToggleDeinterlace(_ sender: NSMenuItem) {
    player.toggleDeinterlace(sender.state != .on)
  }

  @objc
  func menuToggleVideoFilterString(_ sender: NSMenuItem) {
    if let string = (sender.representedObject as? String) {
      menuToggleFilterString(string, forType: MPVProperty.vf)
    }
  }

  private func menuToggleFilterString(_ string: String, forType type: String) {
    let isVideo = type == MPVProperty.vf
    if let filter = MPVFilter(rawString: string) {
      // Removing a filter based on its position within the filter list is the preferred way to do
      // it as per discussion with the mpv project. Search the list of filters and find the index
      // of the specified filter (if present).
      if let index = player.mpv.getFilters(type).firstIndex(of: filter) {
        // remove
        if isVideo {
          _ = player.removeVideoFilter(filter, index)
        } else {
          _ = player.removeAudioFilter(filter, index)
        }
      } else {
        // add
        if isVideo {
          if !player.addVideoFilter(filter) {
            Utility.showAlert("filter.incorrect")
          }
        } else {
          if !player.addAudioFilter(filter) {
            Utility.showAlert("filter.incorrect")
          }
        }
      }
    }
    let vfWindow = AppDelegate.shared.vfWindow
    if vfWindow.loaded {
      vfWindow.reloadTable()
    }
  }
}

// MARK: - Audio

extension MainMenuActionHandler {
  @objc func menuLoadExternalAudio(_ sender: NSMenuItem) {
    let currentDir = player.info.currentURL?.deletingLastPathComponent()
    Utility.quickOpenPanel(title: "Load external audio file", chooseDir: false, dir: currentDir,
                           sheetWindow: player.currentWindow,
                           allowedFileTypes: Utility.playableFileExt) { url in
      self.player.loadExternalAudioFile(url)
    }
  }

  @objc func menuChangeVolume(_ sender: NSMenuItem) {
    if let volumeDelta = sender.representedObject as? Double {
      player.setVolume(volumeDelta + player.info.volume)
    } else if let volumeDelta = sender.representedObject as? Int {
      player.setVolume(Double(volumeDelta) + player.info.volume)
    } else {
      Logger.log("sender.representedObject is not int in menuChangeVolume()", level: .error)
    }
  }

  @objc func menuToggleMute(_ sender: NSMenuItem) {
    player.toggleMute()
  }

  @objc func menuChangeAudioDelay(_ sender: NSMenuItem) {
    if let delayDelta = sender.representedObject as? Double {
      let newDelay = player.info.audioDelay + delayDelta
      player.setAudioDelay(newDelay)
    } else {
      Logger.log("sender.representedObject is not Double in menuChangeAudioDelay()", level: .error)
    }
  }

  @objc func menuResetAudioDelay(_ sender: NSMenuItem) {
    player.setAudioDelay(0)
  }

  @objc
  func menuToggleAudioFilterString(_ sender: NSMenuItem) {
    if let string = (sender.representedObject as? String) {
      menuToggleFilterString(string, forType: MPVProperty.af)
    }
  }
}

// MARK: - Sub

extension MainMenuActionHandler {
  @objc func menuLoadExternalSub(_ sender: NSMenuItem) {
    let currentDir = player.info.currentURL?.deletingLastPathComponent()
    // In addition to subtitle files allow the user to choose video files as mpv will look for and
    // load embedded subtitle streams in the video file.
    Utility.quickOpenPanel(title: "Load external subtitle", chooseDir: false, dir: currentDir,
                           sheetWindow: player.currentWindow,
                           allowedFileTypes: Utility.containsSubExt) { url in
      self.player.loadExternalSubFile(url, delay: true)
    }
  }

  @objc func menuToggleSubVisibility(_ sender: NSMenuItem) {
    player.toggleSubVisibility()
  }

  @objc func menuToggleSecondSubVisibility(_ sender: NSMenuItem) {
    player.toggleSecondSubVisibility()
  }

  @objc func menuToggleSubtitleTranslation(_ sender: NSMenuItem) {
    player.subtitleTranslation.userSetEnabled(!player.subtitleTranslation.isEnabled)
    sender.state = player.subtitleTranslation.isEnabled ? .on : .off
  }

  // MARK: - Live translation

  @objc func menuToggleLiveTranslation(_ sender: NSMenuItem) {
    Preference.set(!LiveTranslationPreferences.enabled, for: .liveTranslationEnabled)
    sender.state = LiveTranslationPreferences.enabled ? .on : .off
  }

  @objc func menuSetLiveTranslationLanguage(_ sender: NSMenuItem) {
    let id = sender.representedObject as? String
    let language = id.flatMap(LiveTranslationLanguages.language(for:))
    player.liveTranslationLanguage.setOverride(language)
  }

  @objc func menuToggleLiveTranslationSource(_ sender: NSMenuItem) {
    Preference.set(!LiveTranslationPreferences.showSource,
                   for: .liveTranslationShowSource)
    sender.state = LiveTranslationPreferences.showSource ? .on : .off
  }

  @objc func menuOpenLiveTranslationSettings(_ sender: Any?) {
    SettingsWindow.default.showPage(identifier: "liveTranslation")
  }

  @objc func menuOpenSystemAudioSettings(_ sender: Any?) {
    guard let url = URL(string:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc func menuCorrectLiveTranslationCaption(_ sender: Any?) {
    guard let snapshot =
            player.liveTranslationCaptions.correctionSnapshot() else { return }
    let current = snapshot.target
    guard !current.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "Correct the Last Caption", comment: "Live translation correction")
    alert.informativeText = NSLocalizedString(
      "The correction is remembered for this show and used in future lines.",
      comment: "Live translation correction")
    let field = NSTextField(frame: NSRect(
      x: 0, y: 0, width: Tokens.Size.n300, height: Tokens.Size.n25))
    field.stringValue = current
    field.setAccessibilityLabel(NSLocalizedString(
      "Corrected Caption", comment: "Live translation correction"))
    alert.accessoryView = field
    alert.addButton(withTitle: NSLocalizedString(
      "Save Correction", comment: "Live translation correction"))
    alert.addButton(withTitle: NSLocalizedString(
      "Cancel", comment: "Live translation correction"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    player.liveTranslationCaptions.applyCorrection(
      field.stringValue, to: snapshot)
  }

  @objc func menuChangeSubDelay(_ sender: NSMenuItem) {
    if let delayDelta = sender.representedObject as? Double {
      let newDelay = player.info.subDelay + delayDelta
      player.setSubDelay(newDelay)
    } else {
      Logger.log("sender.representedObject is not Double in menuChangeSubDelay()", level: .error)
    }
  }

  @objc func menuChangeSubScale(_ sender: NSMenuItem) {
    if sender.tag == 0 {
      player.setSubScale(1)
      return
    }
    let multiplier: Double
    if let value = sender.representedObject as? Double, value > 0, value != 1 {
      multiplier = value
    } else {
      multiplier = sender.tag > 0 ? 1.1 : 0.9
    }
    let currentScale = player.mpv.getDouble(MPVOption.Subtitles.subScale)
    let scaled = abs(currentScale * multiplier)
    player.setSubScale(min(10, max(0.1, scaled)))
  }

  @objc func menuResetSubDelay(_ sender: NSMenuItem) {
    player.setSubDelay(0)
  }

  @objc func menuSetSubEncoding(_ sender: NSMenuItem) {
    player.setSubEncoding((sender.representedObject as? String) ?? "auto")
    player.reloadAllSubs()
  }

  @objc func menuSubFont(_ sender: NSMenuItem) {
    player.chooseSubFont()
  }

  @objc func menuFindOnlineSub(_ sender: NSMenuItem) {
    // return if last search is not finished
    guard let url = player.info.currentURL, !player.isSearchingOnlineSubtitle else { return }

    player.isSearchingOnlineSubtitle = true
    let searchURL = url
    OnlineSubtitle.search(forFile: url, player: player, providerID: sender.representedObject as? String) { urls in
      defer { self.player.isSearchingOnlineSubtitle = false }
      guard self.player.info.currentURL == searchURL else {
        // Playback changed while the search ran; the subtitles belong to the
        // previous file.
        self.player.sendOSD(.foundSub(0))
        return
      }
      if urls.isEmpty {
        self.player.sendOSD(.foundSub(0))
      } else {
        self.player.downloadedSubtitleURLs.formUnion(urls)
        for url in urls {
          Logger.log("Saved subtitle to \(url.path)")
          self.player.loadExternalSubFile(url)
        }
        self.player.sendOSD(.downloadedSub(
          urls.map({ $0.lastPathComponent }).joined(separator: "\n")
        ))
      }
    }
  }

  @objc func saveDownloadedSub(_ sender: NSMenuItem) {
    let selected = player.info.$subTracks.withLock { $0.filter { $0.id == player.info.sid } }
    guard selected.count > 0 else {
      Utility.showAlert("sub.no_selected")

      return
    }
    let sub = selected[0]
    // Make sure it is a subtitle this session downloaded, not any local file.
    guard let path = sub.externalFilename,
          player.downloadedSubtitleURLs.contains(URL(fileURLWithPath: path)) else {
      Utility.showAlert("sub.no_selected")
      return
    }
    let subURL = URL(fileURLWithPath: path)
    let subFileName = subURL.lastPathComponent
    let windowTitle = NSLocalizedString("alert.sub.save_downloaded.title", comment: "Save Downloaded Subtitle")
    Utility.quickSavePanel(title: windowTitle, filename: subFileName, sheetWindow: player.currentWindow) { (destURL) in
      guard subURL.standardizedFileURL != destURL.standardizedFileURL else { return }
      do {
        // Copy beside the destination first; only replace it after the copy
        // succeeds so a failed copy cannot remove the user's file.
        let stagedURL = destURL.deletingLastPathComponent()
          .appendingPathComponent(".uniplayer-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: subURL, to: stagedURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        if FileManager.default.fileExists(atPath: destURL.path) {
          try FileManager.default.trashItem(at: destURL, resultingItemURL: nil)
          Logger.log("Trashed existing subtitle file \(destURL)")
        }
        try FileManager.default.moveItem(at: stagedURL, to: destURL)
        Logger.log("Saved downloaded subtitle to \(destURL.path)")
        self.player.sendOSD(.savedSub)
      } catch let error as NSError {
        Utility.showAlert("error_saving_file", arguments: ["subtitle", error.localizedDescription])
      }
    }
  }

  @objc func menuCycleTrack(_ sender: NSMenuItem) {
    switch sender.tag {
    case 0: player.mpv.command(.cycle, args: ["video"])
    case 1: player.mpv.command(.cycle, args: ["audio"])
    case 2: player.mpv.command(.cycle, args: ["sub"])
    default: break
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(menuDeleteCurrentFile(_:)), #selector(menuShowCurrentFileInFinder(_:)):
      return player.info.currentURL != nil && !player.info.isNetworkResource
    case #selector(menuReturnToInline(_:)):
      return !player.isInline && player.info.state.active
    case #selector(menuToggleLibraryFocus(_:)):
      menuItem.state = player.initialWindow.isFocusMode ? .on : .off
      return player.initialWindow.supportsFocusMode
    case #selector(menuToggleSubtitleTranslation(_:)):
      menuItem.state = player.subtitleTranslation.isEnabled ? .on : .off
      return player.info.state.active
    case #selector(menuToggleLiveTranslation(_:)):
      menuItem.state = LiveTranslationPreferences.enabled ? .on : .off
      return player.info.state.active
    case #selector(menuToggleLiveTranslationSource(_:)):
      menuItem.state = LiveTranslationPreferences.showSource ? .on : .off
      return player.info.state.active
    case #selector(menuCorrectLiveTranslationCaption(_:)):
      return !player.liveTranslationCaptions.latestTargetLine.isEmpty
    case #selector(menuSetLiveTranslationLanguage(_:)):
      return player.info.state.active
    default:
      break
    }
    return true
  }

  // MARK: - Plugin

  @objc func showPluginsPanel(_ sender: NSMenuItem) {
    player.mainWindow.sidebars.show(sidebar: .plugins)
  }
}
