import Foundation
import Network

private struct ResponseEnvelope<R: Decodable>: Decodable {
    let result: R
}

public struct HerdrError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

/// Resume-exactly-once guard for Network.framework callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// One NDJSON connection to the herdr socket.
///
/// Verified against herdr 0.7.x (protocol v16/v17): connections are ONE-SHOT.
/// - request: one request, one response, then the server closes the socket.
///   Use a fresh connection per request.
/// - event stream: `events.subscribe` as the single request keeps the
///   connection open as a dedicated push stream. ANY further write makes the
///   server close it. To change subscriptions, open a new connection with the
///   full set and close the old one. On subscribe the server REPLAYS buffered
///   recent events — consumers must tolerate stale deliveries.
public actor HerdrConnection {
    private let path: String
    private var conn: NWConnection?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var counter = 0
    private var eventCont: AsyncStream<(event: String, data: Data)>.Continuation?
    private var closed = false

    public init(socketPath: String) {
        self.path = socketPath
    }

    public func connect() async throws {
        let c = NWConnection(to: .unix(path: path), using: .tcp)
        conn = c
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { k.resume() }
                case .failed(let error):
                    once.run { k.resume(throwing: error) }
                case .cancelled:
                    once.run { k.resume(throwing: HerdrError(code: "cancelled", message: "connection cancelled")) }
                default:
                    break
                }
            }
            c.start(queue: .global())
        }
        // Post-ready: route later failures into teardown.
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.teardown() }
            default:
                break
            }
        }
        receiveNext()
    }

    /// Send a request and decode the `result` payload.
    public func request<T: Decodable & Sendable>(
        _ method: String,
        params: JSON = .object([:]),
        as type: T.Type
    ) async throws -> T {
        let data = try await rawRequest(method, params: params)
        return try JSONDecoder().decode(ResponseEnvelope<T>.self, from: data).result
    }

    /// Subscribe and turn this connection into a dedicated event stream.
    /// Do not call `request` afterwards — the server will drop the connection.
    public func subscribe(_ subscriptions: [JSON]) async throws -> AsyncStream<(event: String, data: Data)> {
        let (stream, cont) = AsyncStream<(event: String, data: Data)>.makeStream()
        eventCont = cont
        _ = try await request(
            "events.subscribe",
            params: ["subscriptions": .array(subscriptions)],
            as: SubscriptionAck.self
        )
        return stream
    }

    public func close() {
        teardown()
    }

    // MARK: - internals

    private func rawRequest(_ method: String, params: JSON) async throws -> Data {
        guard !closed, let conn else {
            throw HerdrError(code: "closed", message: "connection is closed")
        }
        counter += 1
        let id = "req\(counter)"
        let obj: [String: Any] = ["id": id, "method": method, "params": params.any]
        var payload = try JSONSerialization.data(withJSONObject: obj)
        payload.append(0x0A)
        return try await withCheckedThrowingContinuation { k in
            pending[id] = k
            conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { await self?.fail(id: id, error: error) }
                }
            })
            // A socket that connects but never answers (e.g. herdr's --remote
            // attach proxy) must not hang the bridge forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.fail(id: id, error: HerdrError(code: "timeout", message: "no reply in 8s — not an API socket?"))
            }
        }
    }

    private func receiveNext() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, complete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, complete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            buffer.append(data)
            drainLines()
        }
        if complete || error != nil {
            teardown()
            return
        }
        receiveNext()
    }

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            route(line)
        }
    }

    private func route(_ line: Data) {
        if ProcessInfo.processInfo.environment["HERD_DEBUG"] != nil {
            let s = String(data: line.prefix(200), encoding: .utf8) ?? "<bin>"
            FileHandle.standardError.write(Data("[route] \(s)\n".utf8))
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            eventCont?.yield((event: event, data: line))
            return
        }
        guard let id = obj["id"] as? String, let k = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            k.resume(throwing: HerdrError(
                code: err["code"] as? String ?? "error",
                message: err["message"] as? String ?? "unknown error"
            ))
        } else {
            k.resume(returning: line)
        }
    }

    private func fail(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        conn?.cancel()
        conn = nil
        for (_, k) in pending {
            k.resume(throwing: HerdrError(code: "closed", message: "connection closed"))
        }
        pending.removeAll()
        eventCont?.finish()
        eventCont = nil
    }
}
