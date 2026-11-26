import Foundation

/// A serial URLSession delegate writes whole network chunks. An interrupted transfer
/// leaves a prefix on disk that can resume after cancellation, failure or app restart.
final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let output: FileHandle
    private let size: Int64
    private let progress: @Sendable (Int64) -> Void
    private var received: Int64
    private var lastProgress: TimeInterval = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(output: FileHandle, received: Int64, size: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.output = output
        self.received = received
        self.size = size
        self.progress = progress
    }

    func run(url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 60 * 24
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                lock.lock()
                self.task = task
                self.continuation = continuation
                let stop = cancelled
                lock.unlock()
                task.resume()
                if stop { task.cancel() }
                session.finishTasksAndInvalidate()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let running = task; lock.unlock()
        running?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw ModelError("Model server returned HTTP \(code). Retry the download to resume.")
            }
            if http.statusCode == 206 {
                let range = http.value(forHTTPHeaderField: "Content-Range")
                guard range == "bytes \(received)-\(size - 1)/\(size)" else { throw ModelError("The model server returned an unexpected byte range.") }
            } else { received = 0 }
            try output.truncate(atOffset: UInt64(received))
            try output.seek(toOffset: UInt64(received))
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard received + Int64(data.count) <= size else { throw ModelError("The downloaded file exceeds its declared size.") }
            try output.write(contentsOf: data)
            received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if received == size || now - lastProgress > 0.2 { lastProgress = now; progress(received) }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let stopped = cancelled; self.task = nil; lock.unlock()
        if stopped { continuation?.resume(throwing: CancellationError()) }
        else if let problem = failure ?? error { continuation?.resume(throwing: problem) }
        else if received != size { continuation?.resume(throwing: ModelError("Incomplete model download. Retry to resume.")) }
        else { continuation?.resume() }
        continuation = nil
    }
}
