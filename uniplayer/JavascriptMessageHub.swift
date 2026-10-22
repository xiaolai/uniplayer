//
//  JavascriptMessageHub.swift
//  uniplayer
//
//  Created by Collider LI on 22/10/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Foundation
import WebKit


class JavascriptMessageHub {
  weak var reference: JavascriptAPI!
  private var listeners: [String: JSManagedValue] = [:]

  init(reference: JavascriptAPI) {
    self.reference = reference
  }

  func postMessage(to webView: WKWebView, name: String, data: JSValue) {
    DispatchQueue.main.async {
      var arguments: [String: Any] = ["name": name]
      if let object = data.toObject() {
        arguments["data"] = object
      }
      webView.callAsyncJavaScript(
        "window.iina._emit(name, data)",
        arguments: arguments,
        in: nil,
        in: .page,
        completionHandler: nil)
    }
  }

  func clearListeners() {
    listeners.removeAll()
  }

  func addListener(forEvent name: String, callback: JSValue) {
    if let previousCallback = listeners[name] {
      JSContext.current()!.virtualMachine.removeManagedReference(previousCallback, withOwner: reference)
    }
    let managed = JSManagedValue(value: callback)
    listeners[name] = managed
    JSContext.current()!.virtualMachine.addManagedReference(managed, withOwner: reference)
  }

  func callListener(forEvent name: String, withDataString dataString: String?) {
    guard let callback = listeners[name] else { return }

    let context = callback.value.context
    var jsValue: JSValue?

    if let dataString, let data = dataString.data(using: .utf8) {
      if dataString.hasPrefix("\"") && dataString.hasSuffix("\"") {
        // is a string
        jsValue = JSValue(object: String(dataString.dropFirst().dropLast()), in: context)
      } else if Regex.numbers.matches(dataString) {
        // is a number
        jsValue = JSValue(object: Double(dataString), in: context)
      } else if dataString == "true" || dataString == "false" {
        // is a boolean
        jsValue = JSValue(object: dataString == "true", in: context)
      } else {
        // json object
        if let decoded = try? JSONSerialization.jsonObject(with: data) {
          jsValue = JSValue(object: decoded, in: context)
        }
      }
    }

    if let jsValue {
      callback.value.call(withArguments: [jsValue])
    } else {
      callback.value.call(withArguments: [])
    }
  }

  func callListener(forEvent name: String, withDataObject dataObject: Any?, userInfo: Any? = nil) {
    guard let callback = listeners[name] else { return }
    let data = JSValue(object: dataObject, in: callback.value.context) ?? NSNull()
    let userInfo = userInfo ?? NSNull()
    callback.value.call(withArguments: [data, userInfo])
  }

  func receiveMessageFromUserContentController(_ message: WKScriptMessage) {
    guard let dict = message.body as? [Any], dict.count == 2,
      let name = dict[0] as? String
      else { return }

    callListener(forEvent: name, withDataString: dict[1] as? String)
  }

  static let bridgeScript = """
window.iina = {
  listeners: {},
  _emit(name, data) {
    const callback = this.listeners[name];
    if (typeof callback === "function") {
      callback.call(null, data);
    }
  },
  _simpleModeSetStyle(string) {
    document.getElementById("style").innerHTML = string;
  },
  _simpleModeSetContent(string) {
    document.getElementById("content").innerHTML = string;
  },
  onMessage(name, callback) {
    this.listeners[name] = callback;
  },
  postMessage(name, data) {
    webkit.messageHandlers.iina.postMessage([name, JSON.stringify(data)]);
  },
};
"""
}
