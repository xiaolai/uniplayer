//
//  JavascriptAPIEvent.swift
//  uniplayer
//
//  Created by Collider LI on 11/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

@objc protocol JavascriptAPIEventExportable: JSExport {
  func on(_ event: String, _ callback: JSValue) -> String?
  func off(_ event: String, _ id: String)
}

// Examples:
// event.on("mpv.file-start")
// event.on("mpv.fullscreen.changed")
// event.on("iina.window-resized")
// event.on("iina.pip.changed")

class JavascriptAPIEvent: JavascriptAPI, JavascriptAPIEventExportable {
  private var addedListeners: [(String, EventController.Name)] = []

  @objc func on(_ event: String, _ callback: JSValue) -> String? {
    let components = event.split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
      throwError(withMessage: "Incorrect event name syntax: \"\(event)\"")
      return nil
    }
    let isEventListener = components.count == 2
    let isPropertyChangedListener = components.count == 3 && components[2] == "changed"
    let isMpv = components[0] == "mpv"
    let isUniPlayer = components[0] == "iina"
    guard (isEventListener || isPropertyChangedListener) && (isMpv || isUniPlayer) else {
      throwError(withMessage: "Incorrect event name syntax: \"\(event)\"")
      return nil
    }
    let eventName = String(components[1])
    if isMpv && isPropertyChangedListener && player!.mpv.observeProperties[eventName] == nil {
      player!.mpv.observe(property: eventName)
    }
    let name = EventController.Name(event)
    let id = player!.events.addListener(JavascriptAPIEventCallback(callback), for: name)
    addedListeners.append((id, name))
    return id
  }

  @objc func off(_ event: String,_ id: String) {
    if !player!.events.removeListener(id, for: .init(event)) {
      log("Event listener not found for id \(id)", level: .warning)
    }
  }

  override func cleanUp(_ instance: JavascriptPluginInstance) {
    addedListeners.forEach { (id, name) in
      player!.events.removeListener(id, for: name)
    }
    addedListeners.removeAll()
  }
}

class JavascriptAPIEventCallback: EventCallable {
  private var callback: JSValue?

  init(_ callback: JSValue) {
    self.callback = callback
  }

  func call(withArguments args: [Any]) {
    callback?.call(withArguments: args.map { arg in
      if let rect = arg as? CGRect {
        return JSValue(rect: rect, in: callback!.context)!
      } else {
        return arg
      }
    })
  }
}
