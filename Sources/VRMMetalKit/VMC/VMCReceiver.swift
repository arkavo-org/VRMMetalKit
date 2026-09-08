//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import Network

/// Thin UDP listener that decodes OSC datagrams and hands them to a callback.
///
/// VMC senders default to port 39539 (marionette) and 39540 (performer).
/// Pass port `0` to let the system choose; read the assigned port from
/// ``boundPort`` once ``waitUntilReady(timeout:)`` returns `true`.
public final class VMCReceiver: @unchecked Sendable {

    public enum ReceiverError: Error, LocalizedError {
        case alreadyStarted
        case listenerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted:
                return "VMCReceiver.start() was called while already listening. Call stop() first."
            case .listenerFailed(let reason):
                return "VMCReceiver could not open its UDP port: \(reason). Check that no other VMC app owns the port and that Local Network access is granted. Spec: https://protocol.vmc.info/english"
            }
        }
    }

    public let requestedPort: UInt16
    public private(set) var boundPort: UInt16?

    /// Called on the receiver queue with every decoded packet.
    public var onPacket: (@Sendable (OSCPacket) -> Void)?
    /// Called on the receiver queue when a datagram fails to decode or the listener fails.
    public var onError: (@Sendable (Error) -> Void)?

    public private(set) var packetCount: Int = 0
    public private(set) var decodeErrorCount: Int = 0

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let ready = DispatchSemaphore(value: 0)
    private var readySignalled = false

    public init(port: UInt16 = 39539, queue: DispatchQueue = DispatchQueue(label: "com.arkavo.vrmmetalkit.vmc-receiver")) {
        self.requestedPort = port
        self.queue = queue
    }

    /// Convenience: a receiver whose packets go straight into `driver`.
    public convenience init(port: UInt16 = 39539, driver: VMCDriver) {
        self.init(port: port)
        onPacket = { [driver] packet in driver.receive(packet) }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { throw ReceiverError.alreadyStarted }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
        let listener = try NWListener(using: params, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.boundPort = listener.port?.rawValue
                let signal = !self.readySignalled
                self.readySignalled = true
                self.lock.unlock()
                if signal { self.ready.signal() }
            case .failed(let error):
                self.onError?(ReceiverError.listenerFailed(error.localizedDescription))
                self.lock.lock()
                let signal = !self.readySignalled
                self.readySignalled = true
                self.lock.unlock()
                if signal { self.ready.signal() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Blocks until the listener is ready or failed. Returns `true` when a port is bound.
    public func waitUntilReady(timeout: TimeInterval = 2.0) -> Bool {
        _ = ready.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return boundPort != nil
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections = []
        self.boundPort = nil
        self.readySignalled = false
        lock.unlock()
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.remove(connection) }
            if case .cancelled = state { self.remove(connection) }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                do {
                    let packet = try OSCPacket.decode(data)
                    self.lock.lock()
                    self.packetCount += 1
                    self.lock.unlock()
                    self.onPacket?(packet)
                } catch {
                    self.lock.lock()
                    self.decodeErrorCount += 1
                    self.lock.unlock()
                    self.onError?(error)
                }
            }
            if error == nil, connection.state != .cancelled {
                self.receiveLoop(connection)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }
}
