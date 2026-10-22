//
//  JavascriptAPIWebSocket.swift
//  uniplayer
//
//  Created by Hechen Li on 8/8/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore
import Network

@objc protocol JavascriptAPIWebSocketControllerExportable: JSExport {
  func createServer(_ options: [String: Any])
  func startServer()
  func onStateUpdate(_ handler: JSValue)
  func onMessage(_ handler: JSValue)
  func onNewConnection(_ handler: JSValue)
  func onConnectionStateUpdate(_ handler: JSValue)
  func sendText( _ conn: String, _ string: String) -> JSValue
}

class JavascriptAPIWebSocketController: JavascriptAPI, JavascriptAPIWebSocketControllerExportable {
  var server: WebSocketServer?
  var stateHandler: JSManagedValue?
  var messageHandler: JSManagedValue?
  var newConnHandler: JSManagedValue?
  var connStateHandler: JSManagedValue?

  func createServer(_ options: [String : Any]) {
    guard permitted(to: .networkListener) else {
      throwError(withMessage: "ws.createServer: the network-listener permission is required")
      return
    }
    if let previousServer = server {
      previousServer.stop()
      self.server = nil
    }
    guard let port = (options["port"] as? NSNumber)?.uint16Value else {
      throwError(withMessage: "ws.createServer: port not specified")
      return
    }
    server = WebSocketServer(port: port, label: "\(pluginInstance.plugin.identifier).ws")
    // The server should be created without any issue at this step,
    // but errors may occur if we add TLS support in the future.
    if server == nil {
      throwError(withMessage: "ws.createServer: server cannot be created.")
      return
    }
    server?.delegate = self
    return
  }

  func startServer() {
    guard let server else {
      throwError(withMessage: "ws.startServer: server not created")
      return
    }
    guard server.listener.state == .setup else {
      throwError(withMessage: "ws.startServer: server is not in ready state")
      return
    }
    server.start()
  }

  func onMessage(_ handler: JSValue) {
    setHandler(handler, field: \Self.messageHandler)
  }

  func onStateUpdate(_ handler: JSValue) {
    setHandler(handler, field: \Self.stateHandler)
  }

  func onNewConnection(_ handler: JSValue) {
    setHandler(handler, field: \Self.newConnHandler)
  }

  func onConnectionStateUpdate(_ handler: JSValue) {
    setHandler(handler, field: \Self.connStateHandler)
  }

  private func setHandler(_ handler: JSValue, field: ReferenceWritableKeyPath<JavascriptAPIWebSocketController, JSManagedValue?>) {
    if let previous = self[keyPath: field] {
      JSContext.current()!.virtualMachine.removeManagedReference(previous, withOwner: self)
      self[keyPath: field] = nil
    }
    guard !handler.isNull, !handler.isUndefined else { return }
    guard handler.isObject else {
      throwError(withMessage: "ws.on: the handler is not an object")
      return
    }
    let managed = JSManagedValue(value: handler)
    self[keyPath: field] = managed
    JSContext.current()!.virtualMachine.addManagedReference(managed, withOwner: self)
  }

  func sendText(_ conn: String, _ string: String) -> JSValue {
    guard let data = string.data(using: .utf8) else {
      return JSValue(undefinedIn: context)
    }

    return createPromise { [unowned self] resolve, reject in
      guard let server = self.server else {
        reject.call(withArguments: ["server does not exist"])
        return
      }
      server.send(data: data, toID: conn, opcode: .text) { result in
        self.pluginInstance.queue.async {
          switch result {
          case .sent:
            resolve.call(withArguments: ["success"])
          case .noConnection:
            // Not the server's fault; treat it as an ignorable request.
            resolve.call(withArguments: ["no_connection"])
          case .failed(let error):
            reject.call(withArguments: [error.toDict()])
          }
        }
      }
    }
  }

  override func cleanUp(_ instance: JavascriptPluginInstance) {
    server?.stop()
    server = nil
  }
}


extension JavascriptAPIWebSocketController: WebSocketServerDelegate {
  private func emit(_ handler: JSManagedValue?, _ arguments: [Any?]) {
    guard let value = handler?.value else { return }
    pluginInstance.queue.async {
      value.call(withArguments: arguments.map { $0 ?? NSNull() })
    }
  }

  func stateUpdated(_ state: NWListener.State) {
    let name: String
    var extra: Any?
    switch state {
    case .setup:
      name = "setup"
    case .waiting(let error):
      name = "waiting"
      extra = error.toDict()
    case .ready:
      name = "ready"
    case .failed(let error):
      name = "failed"
      extra = error.toDict()
    case .cancelled:
      name = "cancelled"
    @unknown default:
      name = "\(state)"
    }
    emit(stateHandler, extra.map { [name, $0] } ?? [name])
  }

  func newConnection(_ conn: NWConnection, connID: String) {
    emit(newConnHandler, [
      connID,
      ["path": conn.currentPath?.remoteEndpoint?.debugDescription] as [String: Any?]
    ])
  }

  func connection(_ conn: String, stateUpdated state: NWConnection.State) {
    let name: String
    var extra: Any?
    switch state {
    case .setup:
      name = "setup"
    case .waiting(let error):
      name = "waiting"
      extra = error.toDict()
    case .preparing:
      name = "preparing"
    case .ready:
      name = "ready"
    case .failed(let error):
      name = "failed"
      extra = error.toDict()
    case .cancelled:
      name = "cancelled"
    @unknown default:
      name = "\(state)"
    }
    emit(connStateHandler, extra.map { [conn, name, $0] } ?? [conn, name])
  }

  func connection(_ conn: String, receivedData data: Data, context: NWConnection.ContentContext) {
    emit(messageHandler, [conn, WSMessage(data: data)])
  }
}


@objc fileprivate protocol WSMessageExportable: JSExport {
  func text() -> String?
  func data() -> JSValue?
}


/// Represents a WebSocket message, passed to JavaScript environment. Do not decode the message right away
/// since we don't know whether the JavaScript code need text or binary data, and creating UInt8Array can be expensive
@objc fileprivate class WSMessage: NSObject, WSMessageExportable {
  let dataObject: Data

  init(data: Data) {
    self.dataObject = data
  }

  func text() -> String? {
    return String(data: dataObject, encoding: .utf8)
  }

  func data() -> JSValue? {
    return createUInt8Array(fromData: dataObject)
  }
}

fileprivate extension Error where Self : CustomDebugStringConvertible {
  func toDict() -> [String: Any] {
    return [
      "description": self.debugDescription,
      "message": self.localizedDescription,
    ]
  }
}
