//
//  WebSocketServer.swift
//  uniplayer
//
//  Created by Hechen Li on 8/8/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation
import Network


protocol WebSocketServerDelegate: AnyObject {
  func stateUpdated(_ state: NWListener.State)
  func newConnection(_ conn: NWConnection, connID: String)
  func connection(_ conn: String, stateUpdated state: NWConnection.State)
  func connection(_ conn: String, receivedData data: Data, context: NWConnection.ContentContext)
}


class WebSocketServer {
  let label: String
  weak var delegate: WebSocketServerDelegate?

  var listener: NWListener
  private var connections: [String: NWConnection] = [:]

  lazy var serverQueue = DispatchQueue(label: "UniPlayerWebSocketServer.\(self.label)")
  let subsystem: Logger.Subsystem

  init?(port: UInt16, label: String, logger: Logger.Subsystem? = nil) {
    self.label = label
    self.subsystem = logger ?? Logger.makeSubsystem("ws-server")
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      Logger.log("Cannot start WebSocket server on port \(port)", level: .error, subsystem: subsystem)
      return nil
    }
    // Loopback only. LAN exposure is a product decision that needs consent,
    // authentication and TLS; it is not enabled implicitly.
    let parameters = NWParameters(tls: nil)
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = false
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)

    let wsOptions = NWProtocolWebSocket.Options()
    wsOptions.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    do {
      listener = try NWListener(using: parameters)
    } catch {
      Logger.log(error.localizedDescription, level: .error, subsystem: subsystem)
      return nil
    }
  }

  func start() {
    listener.newConnectionHandler = handleNewConnection(_:)
    listener.stateUpdateHandler = handleStateUpdate(_:)
    // No error will be thrown here. If the port is in use, the server will fail immediately
    listener.start(queue: serverQueue)
  }

  func stop() {
    listener.cancel()
    serverQueue.async { [weak self] in
      guard let self else { return }
      self.connections.values.forEach { $0.cancel() }
      self.connections.removeAll()
    }
  }

  private func handleNewConnection(_ connection: NWConnection) {
    // Create a UUID to identify each connection
    let connID = UUID().uuidString
    Logger.log("New connection: \(connID)", level: .debug, subsystem: subsystem)
    Logger.log(connection.debugDescription, level: .debug, subsystem: subsystem)
    connections[connID] = connection
    delegate?.newConnection(connection, connID: connID)

    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      Logger.log("Connection \(state) (\(connID))", subsystem: self.subsystem)
      self.delegate?.connection(connID, stateUpdated: state)
      switch state {
      case .failed:
        connection.cancel()
        fallthrough
      case .cancelled:
        self.connections[connID] = nil
      default:
        break
      }
    }

    connection.start(queue: serverQueue)

    func receive() {
       connection.receiveMessage { [weak self] (data, context, isComplete, error) in
        guard let self else { return }
        if let data, let context {
          // handle ping frames
          if let metadata = context.protocolMetadata as? [NWProtocolWebSocket.Metadata],
             metadata[0].opcode == .ping {
            Logger.log("Ping (\(connID))", subsystem: subsystem)
            let pongContext = NWConnection.ContentContext(
              identifier: "pong",
              metadata: [NWProtocolWebSocket.Metadata(opcode: .pong)]
            )
            connection.send(content: data, contentContext: pongContext, completion: .idempotent)
          } else {
            // normal data
            Logger.log("Data (\(connID))", subsystem: subsystem)
            self.delegate?.connection(connID, receivedData: data, context: context)
          }
          receive()
        }
      }
    }

    receive()
  }

  private func handleStateUpdate(_ state: NWListener.State) {
    Logger.log("Server \(state)", subsystem: subsystem)
    delegate?.stateUpdated(state)
  }

  enum SendResult {
    case sent
    case noConnection
    case failed(NWError)
  }

  /// Send on the server queue; connection lookup and state stay on that queue.
  func send(data: Data, toID connID: String, opcode: NWProtocolWebSocket.Opcode = .binary, completion: @escaping (SendResult) -> Void) {
    serverQueue.async { [weak self] in
      guard let self else { return }
      guard let connection = self.connections[connID] else {
        completion(.noConnection)
        return
      }
      let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
      let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
      connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
        if let error {
          completion(.failed(error))
        } else {
          completion(.sent)
        }
      }))
    }
  }
}

