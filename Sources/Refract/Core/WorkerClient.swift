import Foundation

@MainActor
final class WorkerClient: InferenceClient {
    private let resources: URL?
    init(resources: URL? = Bundle.main.resourceURL) { self.resources = resources }
    lazy var runtimeIdentity: String = {
        guard let url = resources?.appendingPathComponent("runtime-versions.txt"),
              let data = try? String(contentsOf: url, encoding: .utf8) else { return "development" }
        return data
    }()
    private var uniformSize: (Int,Int)?
    private(set) var measuredPeakBytes: UInt64?
    private(set) var processingSize: ModelImageSize?
    private var process: Process?
    private var input: FileHandle?
    private var exiting: Task<Void, Never>?
    private var session = UUID()
    private var route: [String] = []
    private var requestID: String?
    private var completion: CheckedContinuation<Void, Error>?
    private var onProgress: ((Double?, String) -> Void)?
    private var recentError = ""

    func render(_ request: InferenceRequest, progress: @escaping (Double?, String) -> Void) async throws {
        let newRoute = [request.operation, request.modelID ?? "", request.modelPath, request.modelVariant, request.configPath ?? ""]
        if process?.isRunning != true || route != newRoute {
            stop()
            await exiting?.value
            try Task.checkCancellation()
            try start()
            route = newRoute
            uniformSize = (request.width,request.height)
        } else if let size = uniformSize, size != (request.width,request.height) {
            // A process-lifetime peak cannot be attributed to a single size after mixing geometries.
            uniformSize = nil
        }
        measuredPeakBytes = nil
        processingSize = nil
        guard let input, completion == nil else { throw StudioError("Inference worker is busy or unavailable.") }
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            requestID = request.id
            completion = continuation
            onProgress = progress
            do { try input.write(contentsOf: data) }
            catch { finish(.failure(error)) }
        }
    }

    func stop() {
        session = UUID()
        let child = process
        process = nil
        try? input?.close()
        input = nil
        if let child, child.isRunning {
            child.terminate()
            // Wait for Metal contexts to leave the old process before starting a new one.
            // A stuck driver call may ignore Python's signal handler.
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            exiting = Task.detached { child.waitUntilExit() }
        }
        finish(.failure(CancellationError()))
        route = []
    }

    private func start() throws {
        guard let resources else { throw StudioError("The app resources are unavailable.") }
        let python = resources.appendingPathComponent("runtime/bin/python3.12")
        let script = resources.appendingPathComponent("Worker/worker.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw StudioError("Open the packaged Refract.app to use its private inference runtime.")
        }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-I", "-B", "-u", script.path]
        child.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "HF_HUB_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false"
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let token = UUID()
        session = token
        recentError = ""
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        consume(stderr.fileHandleForReading, token: token, events: false)
        consume(stdout.fileHandleForReading, token: token, events: true)
    }

    private func consume(_ handle: FileHandle, token: UUID, events: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var pending = Data()
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                pending.append(bytes)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    DispatchQueue.main.async { [weak self] in self?.receive(line, token: token, events: events) }
                }
                if pending.count > 1_048_576 { pending.removeAll() }
            }
            if events {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session == token else { return }
                    self.finish(.failure(StudioError(self.recentError.isEmpty ? "The inference worker exited unexpectedly." : self.recentError)))
                }
            }
        }
    }

    private struct Event: Decodable {
        let id: String?
        let type: String
        let message: String?
        let fraction: Double?
        let processingWidth: Int?
        let processingHeight: Int?
    }

    private func receive(_ data: Data, token: UUID, events: Bool) {
        guard session == token else { return }
        if !events {
            if let line = String(data: data.suffix(1200), encoding: .utf8), !line.isEmpty { recentError = line }
            return
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: data), event.id == requestID else { return }
        switch event.type {
        case "progress": onProgress?(event.fraction, event.message ?? "Processing")
        case "done":
            if let w = event.processingWidth, let h = event.processingHeight {
                processingSize = ModelImageSize(width: w, height: h)
            }
            if uniformSize != nil, let process {
                var usage = rusage_info_v4()
                let status = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0)
                    }
                }
                if status == 0 { measuredPeakBytes = usage.ri_lifetime_max_phys_footprint }
            }
            finish(.success(()))
        case "error": finish(.failure(StudioError(event.message ?? "Inference failed.")))
        default: break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = completion
        completion = nil
        requestID = nil
        onProgress = nil
        continuation?.resume(with: result)
    }
}
