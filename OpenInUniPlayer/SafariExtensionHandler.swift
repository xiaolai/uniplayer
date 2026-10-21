//
//  SafariExtensionHandler.swift
//  OpenInUniPlayer
//
//  Created by Saagar Jha on 10/8/18.
//  Copyright © 2018 lhc. All rights reserved.
//

import SafariServices

class SafariExtensionHandler: SFSafariExtensionHandler {

  override func toolbarItemClicked(in window: SFSafariWindow) {
    window.getActiveTab {
      $0?.getActivePage {
        $0?.getPropertiesWithCompletionHandler {
          $0?.url.flatMap {
            self.launchUniPlayer(withURL: $0.absoluteString)
          }
        }
      }
    }
  }

  override func validateContextMenuItem(withCommand command: String, in page: SFSafariPage, userInfo: [String: Any]? = nil, validationHandler: @escaping (Bool, String?) -> Void)
  {
    switch command {
    case "OpenInUniPlayer":
      validationHandler(false, nil)
    case "OpenLinkInUniPlayer":
      validationHandler(userInfo?["url"] as? String == nil, nil)
    default:
      assertionFailure("Invalid command")
    }
  }

  override func contextMenuItemSelected(withCommand command: String, in page: SFSafariPage, userInfo: [String: Any]? = nil) {
    switch command {
    case "OpenInUniPlayer":
      page.getPropertiesWithCompletionHandler {
        $0?.url.flatMap {
          self.launchUniPlayer(withURL: $0.absoluteString)
        }
      }
    case "OpenLinkInUniPlayer":
      (userInfo?["url"] as? String).flatMap {
        launchUniPlayer(withURL: $0)
      }
    default:
      assertionFailure("Invalid command")
    }
  }

  func launchUniPlayer(withURL url: String) {
    guard let escapedURL = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
      let url = URL(string: "uniplayer://weblink?url=\(escapedURL)") else {
        return
    }
    NSWorkspace.shared.open(url)
  }
}
