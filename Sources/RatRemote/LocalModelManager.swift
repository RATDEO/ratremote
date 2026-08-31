import Foundation

@MainActor
final class LocalModelManager: ObservableObject {
    static let modelName = "Gemma 4 E2B Instruct Q4_0"
    static let modelFilename = "gemma-4-E2B-it-Q4_0.gguf"
    static let modelDownloadURL = URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf")!

    @Published private(set) var status = "Not installed"
    @Published private(set) var isDownloading = false
    @Published private(set) var isDownloadingRuntime = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastLog = ""

    let port = 11_439
    private var process: Process?
    private var logPipe: Pipe?

    var endpointURL: String { "http://127.0.0.1:\(port)" }

    var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("RatRemote/Models", isDirectory: true)
    }

    var modelURL: URL {
        modelsDirectory.appendingPathComponent(Self.modelFilename)
    }

    var runtimesDirectory: URL {
        modelsDirectory.deletingLastPathComponent().appendingPathComponent("Runtimes/llama.cpp", isDirectory: true)
    }

    var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    var runtimeURL: URL? {
        let candidates: [URL?] = [
            Bundle.main.url(forAuxiliaryExecutable: "llama-server"),
            Bundle.main.resourceURL?.appendingPathComponent("llama-server"),
            managedRuntimeURL,
            URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"),
            URL(fileURLWithPath: "/usr/local/bin/llama-server")
        ]
        for candidate in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("llama-server")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private var managedRuntimeURL: URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: runtimesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "llama-server" {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        if isRunning {
            status = "Ready on this Mac"
        } else if !isModelInstalled {
            status = "Model not installed (about 2.84 GB)"
        } else if runtimeURL == nil {
            status = "Model installed; llama-server is missing"
        } else {
            status = "Installed and stopped"
        }
    }

    func downloadModel() async {
        guard !isDownloading else { return }
        isDownloading = true
        status = "Downloading 2.84 GB…"
        defer { isDownloading = false }

        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let (temporaryURL, response) = try await URLSession.shared.download(from: Self.modelDownloadURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard (try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1_000_000_000 else {
                throw CommandInferenceError.providerUnavailable("The downloaded model file was unexpectedly small.")
            }
            let staged = modelsDirectory.appendingPathComponent(Self.modelFilename + ".download")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: temporaryURL, to: staged)
            try? FileManager.default.removeItem(at: modelURL)
            try FileManager.default.moveItem(at: staged, to: modelURL)
            status = runtimeURL == nil ? "Downloaded; llama-server is missing" : "Installed and stopped"
        } catch {
            status = "Download failed: \(error.localizedDescription)"
        }
    }

    func downloadRuntime() async {
        guard !isDownloadingRuntime else { return }
        isDownloadingRuntime = true
        status = "Finding the latest llama.cpp runtime…"
        defer { isDownloadingRuntime = false }

        do {
            let releaseURL = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest")!
            var releaseRequest = URLRequest(url: releaseURL)
            releaseRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (releaseData, releaseResponse) = try await URLSession.shared.data(for: releaseRequest)
            guard let http = releaseResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(LlamaGitHubRelease.self, from: releaseData)
            #if arch(arm64)
            let platformMarker = "bin-macos-arm64.tar.gz"
            #else
            let platformMarker = "bin-macos-x64.tar.gz"
            #endif
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(platformMarker) }),
                  let downloadURL = URL(string: asset.browserDownloadURL) else {
                throw CommandInferenceError.providerUnavailable("The latest llama.cpp release does not include a compatible macOS runtime.")
            }

            status = "Downloading llama.cpp \(release.tagName)…"
            let (archiveURL, archiveResponse) = try await URLSession.shared.download(from: downloadURL)
            guard let archiveHTTP = archiveResponse as? HTTPURLResponse, (200..<300).contains(archiveHTTP.statusCode) else {
                throw URLError(.badServerResponse)
            }

            try? FileManager.default.removeItem(at: runtimesDirectory)
            try FileManager.default.createDirectory(at: runtimesDirectory, withIntermediateDirectories: true)
            status = "Installing llama.cpp \(release.tagName)…"
            let destination = runtimesDirectory
            let exitStatus = try await Task.detached(priority: .userInitiated) {
                let extractor = Process()
                extractor.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                extractor.arguments = ["-xzf", archiveURL.path, "-C", destination.path]
                try extractor.run()
                extractor.waitUntilExit()
                return extractor.terminationStatus
            }.value
            guard exitStatus == 0, let installedRuntime = managedRuntimeURL else {
                throw CommandInferenceError.providerUnavailable("The llama.cpp runtime archive could not be installed.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedRuntime.path)
            refreshStatus()
        } catch {
            status = "Runtime install failed: \(error.localizedDescription)"
        }
    }

    func ensureRunning() async throws -> String {
        if process?.isRunning == true, isRunning { return endpointURL }
        guard isModelInstalled else {
            throw CommandInferenceError.providerUnavailable("Download \(Self.modelName) in Settings before using it offline.")
        }
        guard let runtimeURL else {
            throw CommandInferenceError.providerUnavailable("llama-server is not installed. Bundle it when building RatRemote or install llama.cpp with Homebrew.")
        }

        stop()
        status = "Starting local model…"
        lastLog = ""

        let pipe = Pipe()
        let process = Process()
        process.executableURL = runtimeURL
        process.arguments = [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", "4096",
            "--jinja",
            "--no-webui"
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = modelsDirectory
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.process === terminated else { return }
                self.isRunning = false
                self.process = nil
                self.status = "Local model stopped (exit \(terminated.terminationStatus))"
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.lastLog = String((self.lastLog + text).suffix(4_000))
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw CommandInferenceError.providerUnavailable("Could not start llama-server: \(error.localizedDescription)")
        }
        self.process = process
        self.logPipe = pipe

        for _ in 0..<120 {
            if !process.isRunning { break }
            if await healthCheck() {
                isRunning = true
                status = "Ready on this Mac"
                return endpointURL
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        let detail = lastLog.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        throw CommandInferenceError.providerUnavailable(
            detail.isEmpty ? "The local model did not become ready in time." : "The local model could not start: \(detail.suffix(600))"
        )
    }

    func stop() {
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        isRunning = false
        refreshStatus()
    }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: endpointURL + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200
        } catch {
            return false
        }
    }
}

private struct LlamaGitHubRelease: Decodable {
    let tagName: String
    let assets: [LlamaGitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct LlamaGitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
