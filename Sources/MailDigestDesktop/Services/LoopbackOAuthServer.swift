import Foundation
import Network

final class LoopbackOAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MailDigest.OAuthLoopback")
    private let expectedState: String
    private let lock = NSLock()
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingResult: Result<URL, Error>?

    init(expectedState: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.expectedState = expectedState
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: OAuthSetupError.invalidCallback)
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
            } else {
                callbackContinuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let requestTarget = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let url = URL(string: "http://127.0.0.1\(requestTarget)")
            let result: Result<URL, Error>

            if let url,
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               components.queryItems?.first(where: { $0.name == "state" })?.value == self.expectedState {
                result = .success(url)
            } else {
                result = .failure(OAuthSetupError.stateMismatch)
            }

            let html = """
            <!doctype html><html lang="zh-Hans"><meta charset="utf-8">
            <title>邮件摘要授权</title>
            <body style="font:16px -apple-system;padding:48px;max-width:520px;margin:auto">
            <h2>授权信息已收到</h2><p>现在可以关闭此页面并返回“邮件摘要”应用。</p>
            </body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.complete(result)
            self.listener.cancel()
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
