//
//  JavascriptPolyfill.swift
//  uniplayer
//
//  Created by Collider LI on 6/3/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import JavaScriptCore

class JavascriptPolyfill {
  private final class TimerEntry {
    let callback: JSValue
    let repeats: Bool

    init(callback: JSValue, repeats: Bool) {
      self.callback = callback
      self.repeats = repeats
    }
  }

  weak var plugin: JavascriptPluginInstance!
  var timers = [String: Timer]()

  init(pluginInstance: JavascriptPluginInstance) {
    self.plugin = pluginInstance
  }

  deinit {
    for timer in timers.values {
      timer.invalidate()
    }
  }

  func removeAllTimers() {
    let remove = {
      self.timers.values.forEach { $0.invalidate() }
      self.timers.removeAll()
    }
    if Thread.isMainThread { remove() } else { DispatchQueue.main.sync(execute: remove) }
  }

  func removeTimer(identifier: String) {
    let remove = { self.timers.removeValue(forKey: identifier)?.invalidate() }
    if Thread.isMainThread { remove() } else { DispatchQueue.main.sync(execute: remove) }
  }

  func createTimer(callback: JSValue, ms: Double, repeats: Bool) -> String {
    let timeInterval = ms / 1000.0
    let uuid = UUID().uuidString
    let install = {
      let timer = Timer.scheduledTimer(timeInterval: timeInterval,
                                       target: self,
                                       selector: #selector(self.callJSCallback),
                                       userInfo: TimerEntry(callback: callback, repeats: repeats),
                                       repeats: repeats)
      self.timers[uuid] = timer
    }
    // Create synchronously so an immediate clearTimeout cannot race the install.
    if Thread.isMainThread { install() } else { DispatchQueue.main.sync(execute: install) }
    return uuid
  }

  @objc func callJSCallback(_ timer: Timer) {
    guard timer.isValid else {
      timers = timers.filter { $0.value !== timer }
      return
    }
    guard let entry = timer.userInfo as? TimerEntry else { return }
    entry.callback.call(withArguments: nil)
    if !entry.repeats {
      timers = timers.filter { $0.value !== timer }
    }
  }

  func register(inContext context: JSContext) {
    let setInterval: @convention(block) (JSValue, Double) -> String = { [unowned self] (callback, ms) in
      return self.createTimer(callback: callback, ms: ms, repeats: true)
    }

    let setTimeout: @convention(block) (JSValue, Double) -> String = { [unowned self] (callback, ms) in
      return self.createTimer(callback: callback, ms: ms, repeats: false)
    }

    let clearInterval: @convention(block) (String) -> () = { [unowned self] identifier in
      self.removeTimer(identifier: identifier)
    }

    let clearTimeout: @convention(block) (String) -> () = { [unowned self] identifier in
      self.removeTimer(identifier: identifier)
    }

    let require: @convention(block) (String, String) -> Any? = { [unowned self] basePath, path in
      guard let instance = self.plugin else { return nil }
      let baseURL = URL(fileURLWithPath: basePath).deletingLastPathComponent()
      let requiredURL = baseURL.appendingPathComponent(path).standardized
      guard requiredURL.isContained(in: instance.plugin.root) else { return nil }
      guard FileManager.default.fileExists(atPath: requiredURL.path) else { return nil }
      return instance.evaluateFile(requiredURL, asModule: true)
    }

    context.setObject(clearInterval, forKeyedSubscript: "clearInterval" as NSString)
    context.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
    context.setObject(setInterval, forKeyedSubscript: "setInterval" as NSString)
    context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
    context.setObject(require, forKeyedSubscript: "__require__" as NSString)
  }
}
