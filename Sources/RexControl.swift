import Foundation

/// A Rex server address: `https://[account@]host[:port]`. The account rides along as an extra
/// WebSocket subprotocol (`rex.as.<account>`), the way the login server expects it.
struct RexEndpoint {
    var base: URL          // https://host:port, no path
    var account: String?

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty,
              c.scheme == "https" || c.scheme == "http", c.path.isEmpty || c.path == "/" else { return nil }
        account = c.user
        if let a = account, a.range(of: "^[A-Za-z0-9._$-]+$", options: .regularExpression) == nil { return nil }
        c.user = nil; c.path = ""
        // ponytail: orex tries TLS:443, TLS:7297, TCP:7297 for bare hosts; we default to 7297 over TLS only (Tailscale certs are real).
        if c.port == nil && !text.contains("://") { c.port = 7297 }
        guard let u = c.url else { return nil }
        base = u
    }

    func socketURL(_ path: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = path
        return c.url!
    }

    func protocols(_ primary: String) -> [String] {
        [primary] + (account.map { ["rex.as.\($0)"] } ?? [])
    }
}

struct RexError: Error, CustomStringConvertible {
    let description: String
}

/// An error as a person reads it: the system's sentence for network trouble, not the NSError dump.
func describe(_ error: Error) -> String {
    if let e = error as? RexError { return e.description }
    return (error as NSError).localizedDescription
}

/// Control connection (`/api/control`, `rex.control.v1`): hello/welcome, request/response by id, events.
@MainActor
final class RexControl {
    let endpoint: RexEndpoint
    var onEvent: ((_ type: String, _ payload: [String: Any]) -> Void)?
    var onClose: ((String) -> Void)?

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var welcome: CheckedContinuation<Void, Error>?

    init(endpoint: RexEndpoint) { self.endpoint = endpoint }

    func connect() async throws {
        let t = session.webSocketTask(with: endpoint.socketURL("/api/control"), protocols: endpoint.protocols("rex.control.v1"))
        task = t
        t.resume()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        try await send(["type": "hello", "api_revision": 13,   // 13: download_begin
                        "client": ["kind": "app", "platform": "ios", "name": "irex", "version": version]])
        receiveLoop(t)
        try await withCheckedThrowingContinuation { welcome = $0 }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        fail("closed")
    }

    /// Sends a request and returns its `payload`; throws the server's `error.message`.
    @discardableResult
    func call(_ method: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let id = String(nextId); nextId += 1
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { do { try await send(["type": "request", "id": id, "method": method, "payload": payload]) }
                   catch { pending.removeValue(forKey: id)?.resume(throwing: error) } }
        }
    }

    private func send(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task?.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, t === self.task else { return }
                switch result {
                case .failure(let e):
                    self.fail(t.closeReason.map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 } ?? e.localizedDescription)
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "welcome":
            if obj["protocol"] as? String == "rex.control.v1" { welcome?.resume() }
            else { welcome?.resume(throwing: RexError(description: "unexpected protocol \(obj["protocol"] ?? "nil")")) }
            welcome = nil
        case "response":
            guard let id = obj["id"] as? String, let cont = pending.removeValue(forKey: id) else { return }
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: RexError(description: err["message"] as? String ?? "\(err)"))
            } else {
                cont.resume(returning: obj["payload"] as? [String: Any] ?? [:])
            }
        case "event":
            if let p = obj["payload"] as? [String: Any], let et = p["type"] as? String {
                onEvent?(et, p["payload"] as? [String: Any] ?? [:])
            }
        default: break
        }
    }

    /// orex never cleared its pending map on disconnect; we fail every waiter so callers can recover.
    private func fail(_ reason: String) {
        let err = RexError(description: reason)
        welcome?.resume(throwing: err); welcome = nil
        let waiters = pending; pending.removeAll()
        waiters.values.forEach { $0.resume(throwing: err) }
        if task != nil { task = nil; onClose?(reason) }
    }
}
