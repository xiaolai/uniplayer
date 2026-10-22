//
//  PrefUtilsViewController.swift
//  uniplayer
//
//  Created by Collider LI on 9/7/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

class PrefUtilsViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefUtilsViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.utilities", comment: "Utilities")
  }

  var preferenceTabImage: NSImage {
    return .sf("wrench.and.screwdriver", withConfiguration: symbolConfiguration)!
  }

  override var sectionViews: [NSView] {
    return [sectionDefaultAppView, sectionClearCacheView, sectionBrowserExtView]
  }

  @IBOutlet var sectionDefaultAppView: NSView!
  @IBOutlet var sectionClearCacheView: NSView!
  @IBOutlet var sectionBrowserExtView: NSView!
  @IBOutlet var setAsDefaultSheet: NSWindow!
  @IBOutlet weak var setAsDefaultVideoCheckBox: NSButton!
  @IBOutlet weak var setAsDefaultAudioCheckBox: NSButton!
  @IBOutlet weak var setAsDefaultPlaylistCheckBox: NSButton!
  @IBOutlet weak var thumbCacheSizeLabel: NSTextField!
  @IBOutlet weak var savedPlaybackProgressClearedLabel: NSTextField!
  @IBOutlet weak var playHistoryClearedLabel: NSTextField!

  override func viewDidLoad() {
    super.viewDidLoad()

    DispatchQueue.main.async {
      self.updateThumbnailCacheStat()
    }
  }

  private func updateThumbnailCacheStat() {
    thumbCacheSizeLabel.stringValue = "\(FloatingPointByteCountFormatter.string(fromByteCount: CacheManager.shared.getCacheSize(), countStyle: .binary))B"
  }

  @IBAction func setUniPlayerAsDefaultAction(_ sender: Any) {
    view.window!.beginSheet(setAsDefaultSheet)
  }

  @IBAction func setAsDefaultOKBtnAction(_ sender: Any) {
    guard let result = UtilityActions.setAsDefaultApplication(
      video: setAsDefaultVideoCheckBox.state == .on,
      audio: setAsDefaultAudioCheckBox.state == .on,
      playlists: setAsDefaultPlaylistCheckBox.state == .on
    ) else { return }

    Utility.showAlert("set_default.success",
                      arguments: [result.succeeded, result.failed],
                      style: .informational,
                      sheetWindow: view.window)
    view.window!.endSheet(setAsDefaultSheet)
  }

  @IBAction func setAsDefaultCancelBtnAction(_ sender: Any) {
    view.window!.endSheet(setAsDefaultSheet)
  }

  @IBAction func clearWatchLaterBtnAction(_ sender: Any) {
    Utility.quickAskPanel("clear_watch_later", sheetWindow: view.window) { respond in
      guard respond == .alertFirstButtonReturn else { return }
      do {
        try UtilityActions.clearWatchLater()
        self.savedPlaybackProgressClearedLabel.isHidden = false
      } catch {
        Utility.showAlert("custom", arguments: ["\(error)"], style: .critical, sheetWindow: self.view.window)
      }
    }
  }

  @IBAction func clearHistoryBtnAction(_ sender: Any) {
    Utility.quickAskPanel("clear_history", sheetWindow: view.window) { respond in
      guard respond == .alertFirstButtonReturn else { return }
      UtilityActions.clearPlaybackHistory()
      self.playHistoryClearedLabel.isHidden = false
    }
  }

  @IBAction func clearCacheBtnAction(_ sender: Any) {
    Utility.quickAskPanel("clear_cache", sheetWindow: view.window) { respond in
      guard respond == .alertFirstButtonReturn else { return }
      UtilityActions.clearThumbnailCache()
      self.updateThumbnailCacheStat()
    }
  }

  @IBAction func extChromeBtnAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.chromeExtensionLink)!)
  }

  @IBAction func extFirefoxBtnAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.firefoxExtensionLink)!)
  }
}
