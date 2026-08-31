import Foundation

private final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum InferenceError: LocalizedError {
    case invalidServerURL
    case insecureServerURL
    case badStatus(Int, String, String)
    case emptyResponse
    case visionTargetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "The inference server URL is invalid."
        case .insecureServerURL:
            "Remote inference servers must use HTTPS. HTTP is permitted only for loopback addresses."
        case .badStatus(let status, let path, let body):
            "Inference server returned HTTP \(status) for \(path): \(body)"
        case .emptyResponse:
            "Inference server returned an empty response."
        case .visionTargetNotFound(let detail):
            "Vision target was not found. \(detail)"
        }
    }
}

@MainActor
final class InferenceClient {
    private let session: URLSession
    private let redirectDelegate: RedirectRejectingSessionDelegate?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let redirectDelegate = RedirectRejectingSessionDelegate()
            self.redirectDelegate = redirectDelegate
            self.session = URLSession(
                configuration: configuration,
                delegate: redirectDelegate,
                delegateQueue: nil
            )
        }
    }

    func health(serverURL: String, apiKey: String) async throws -> String {
        let data = try await request(serverURL: serverURL, apiKey: apiKey, path: "/health", method: "GET", body: Optional<Data>.none)
        return String(data: data, encoding: .utf8) ?? "ok"
    }

    func transcribe(audioURL: URL, serverURL: String, apiKey: String, language: String?) async throws -> String {
        do {
            let response: TranscriptionResponse = try await postFile(
                serverURL: serverURL,
                apiKey: apiKey,
                path: "/transcribe/audio",
                fileURL: audioURL,
                contentType: Self.audioContentType(for: audioURL),
                queryItems: Self.languageQueryItems(language)
            )
            return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch InferenceError.badStatus(let status, _, _) where [404, 405, 501].contains(status) {
            let data = try Data(contentsOf: audioURL)
            let request = TranscriptionRequest(
                audioBase64: data.base64EncodedString(),
                mimeType: Self.audioContentType(for: audioURL),
                language: language
            )
            let response: TranscriptionResponse = try await post(serverURL: serverURL, apiKey: apiKey, path: "/transcribe", body: request)
            return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func transcribe(audioURL: URL, serverURL: String, apiKey: String) async throws -> String {
        try await transcribe(audioURL: audioURL, serverURL: serverURL, apiKey: apiKey, language: nil)
    }

    func command(text: String, screenshotBase64: String?, screenContext: String? = nil, serverURL: String, apiKey: String, agentMode: Bool = false) async throws -> CommandResponse {
        do {
            return try await post(
                serverURL: serverURL,
                apiKey: apiKey,
                path: "/command",
                body: CommandRequest(text: text, screenshotBase64: screenshotBase64, agentMode: agentMode, screenContext: screenContext)
            )
        } catch {
            if shouldTryOpenAICompatibleFallback(after: error) {
                return try await openAICompatibleCommand(
                    text: text,
                    screenContext: screenContext,
                    serverURL: serverURL,
                    apiKey: apiKey,
                    systemPrompt: Self.commandSystemPrompt
                )
            }
            throw error
        }
    }

    func localCommand(text: String, screenContext: String?, serverURL: String) async throws -> CommandResponse {
        try await openAICompatibleCommand(
            text: text,
            screenContext: screenContext,
            serverURL: serverURL,
            apiKey: "",
            systemPrompt: Self.onDeviceCommandSystemPrompt
        )
    }

    func automationStep(
        instruction: String,
        screenshotBase64: String?,
        screenContext: String?,
        stepIndex: Int,
        maxSteps: Int,
        lastActionSummary: String?,
        serverURL: String,
        apiKey: String
    ) async throws -> AutomationStepResponse {
        let request = AutomationStepRequest(
            instruction: instruction,
            screenshotBase64: screenshotBase64,
            screenContext: screenContext,
            stepIndex: stepIndex,
            maxSteps: maxSteps,
            lastActionSummary: lastActionSummary
        )
        do {
            return try await post(serverURL: serverURL, apiKey: apiKey, path: "/automation/step", body: request)
        } catch {
            if shouldTryOpenAICompatibleFallback(after: error) {
                return try await openAICompatibleAutomationStep(request: request, serverURL: serverURL, apiKey: apiKey)
            }
            throw error
        }
    }

    func locate(prompt: String, screenshotBase64: String, serverURL: String, apiKey: String) async throws -> VisionResponse {
        if shouldUseDirectMoondream(serverURL: serverURL) {
            return try await moondreamPoint(prompt: prompt, screenshotBase64: screenshotBase64, serverURL: serverURL, apiKey: apiKey)
        }
        return try await post(
            serverURL: serverURL,
            apiKey: apiKey,
            path: "/vision/locate",
            body: VisionRequest(prompt: prompt, imageBase64: screenshotBase64)
        )
    }

    func screenContext(screenshotBase64: String, serverURL: String, apiKey: String) async throws -> String {
        let endpoint = try moondreamSkillURL(from: serverURL, skill: "query")
        let payload = MoondreamQueryRequest(
            image: "data:image/png;base64,\(screenshotBase64)",
            question: "Briefly describe the visible app or website, current page, and obvious navigation targets. Mention if this is YouTube and whether a video is fullscreen."
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await request(url: endpoint, apiKey: apiKey, method: "POST", body: body)
        let response = try JSONDecoder().decode(MoondreamQueryResponse.self, from: data)
        return response.result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func automationScreenContext(instruction: String, screenshotBase64: String, serverURL: String, apiKey: String) async throws -> String {
        let endpoint = try moondreamSkillURL(from: serverURL, skill: "query")
        let payload = MoondreamQueryRequest(
            image: "data:image/png;base64,\(screenshotBase64)",
            question: """
            Describe only what is visible in the selected target window for this automation instruction:
            \(instruction)

            If the task contains visual criteria, list each observable criterion and whether the current item appears to match it. If a criterion is not clearly visible, note what you can see.
            """
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await request(url: endpoint, apiKey: apiKey, method: "POST", body: body)
        let response = try JSONDecoder().decode(MoondreamQueryResponse.self, from: data)
        return response.result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func post<Request: Encodable, Response: Decodable>(
        serverURL: String,
        apiKey: String,
        path: String,
        body: Request
    ) async throws -> Response {
        let payload = try JSONEncoder().encode(body)
        let data = try await request(serverURL: serverURL, apiKey: apiKey, path: path, method: "POST", body: payload)
        guard !data.isEmpty else { throw InferenceError.emptyResponse }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func postFile<Response: Decodable>(
        serverURL: String,
        apiKey: String,
        path: String,
        fileURL: URL,
        contentType: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        guard var components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InferenceError.invalidServerURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw InferenceError.invalidServerURL
        }

        let data = try await uploadFile(url: url, apiKey: apiKey, method: "POST", fileURL: fileURL, contentType: contentType)
        guard !data.isEmpty else { throw InferenceError.emptyResponse }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func request(serverURL: String, apiKey: String, path: String, method: String, body: Data?) async throws -> Data {
        guard let base = URL(string: serverURL),
              let url = URL(string: path, relativeTo: base) else {
            throw InferenceError.invalidServerURL
        }

        return try await request(url: url, apiKey: apiKey, method: method, body: body)
    }

    private func request(url: URL, apiKey: String, method: String, body: Data?) async throws -> Data {
        try validateTransportSecurity(for: url)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
            request.setValue(trimmedAPIKey, forHTTPHeaderField: "X-API-Key")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if shouldRetryWithCurl(url: url, error: error) {
                return try await curlRequest(url: url, apiKey: apiKey, method: method, body: body)
            }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw InferenceError.badStatus(status, request.url?.path(percentEncoded: false) ?? url.path, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func uploadFile(url: URL, apiKey: String, method: String, fileURL: URL, contentType: String) async throws -> Data {
        try validateTransportSecurity(for: url)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
            request.setValue(trimmedAPIKey, forHTTPHeaderField: "X-API-Key")
        }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL)
        } catch {
            if shouldRetryWithCurl(url: url, error: error) {
                return try await curlUploadFile(url: url, apiKey: apiKey, method: method, fileURL: fileURL, contentType: contentType)
            }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw InferenceError.badStatus(status, request.url?.path(percentEncoded: false) ?? url.path, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func shouldRetryWithCurl(url: URL, error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              nsError.code == NSURLErrorNotConnectedToInternet else {
            return false
        }
        guard let host = url.host else { return false }
        return host == "localhost" ||
            host == "127.0.0.1" ||
            host.hasPrefix("192.168.") ||
            host.hasPrefix("10.") ||
            isPrivate172Address(host)
    }

    private func validateTransportSecurity(for url: URL) throws {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            throw InferenceError.invalidServerURL
        }
        if scheme == "https" { return }
        if scheme == "http", isLoopbackHost(host) { return }
        throw InferenceError.insecureServerURL
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    private func isPrivate172Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "172",
              let second = Int(parts[1]) else {
            return false
        }
        return (16...31).contains(second)
    }

    private func curlRequest(url: URL, apiKey: String, method: String, body: Data?) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var temporaryBodyURL: URL?
            defer {
                if let temporaryBodyURL {
                    try? FileManager.default.removeItem(at: temporaryBodyURL)
                }
            }

            var arguments = [
                "-sS",
                "-m", "120",
                "-X", method,
                "-w", "\\n%{http_code}",
                url.absoluteString
            ]

            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerPipe = Pipe()
            if !trimmedAPIKey.isEmpty {
                // Supplying credentials through stdin keeps them out of the
                // process argument list visible to other local processes.
                arguments.append(contentsOf: ["-H", "@-"])
                process.standardInput = headerPipe
            }

            if let body {
                let bodyURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RatRemote-request-\(UUID().uuidString).json")
                guard FileManager.default.createFile(
                    atPath: bodyURL.path,
                    contents: body,
                    attributes: [.posixPermissions: 0o600]
                ) else { throw CocoaError(.fileWriteUnknown) }
                temporaryBodyURL = bodyURL
                arguments.append(contentsOf: ["-H", "Content-Type: application/json"])
                arguments.append(contentsOf: ["--data-binary", "@\(bodyURL.path)"])
            }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.arguments = arguments

            try process.run()
            if !trimmedAPIKey.isEmpty {
                let headers = "Authorization: Bearer \(trimmedAPIKey)\nX-API-Key: \(trimmedAPIKey)\n"
                headerPipe.fileHandleForWriting.write(Data(headers.utf8))
                try? headerPipe.fileHandleForWriting.close()
            }

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8) ?? "curl exited \(process.terminationStatus)"
                throw InferenceError.badStatus(Int(process.terminationStatus), url.path, message)
            }

            guard let splitIndex = output.lastIndex(of: 10) else {
                throw InferenceError.emptyResponse
            }

            let responseBody = output[..<splitIndex]
            let statusData = output[output.index(after: splitIndex)...]
            let statusText = String(data: Data(statusData), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = Int(statusText) ?? 0
            guard (200..<300).contains(status) else {
                throw InferenceError.badStatus(status, url.path, String(data: Data(responseBody), encoding: .utf8) ?? "")
            }
            return Data(responseBody)
        }.value
    }

    private func curlUploadFile(url: URL, apiKey: String, method: String, fileURL: URL, contentType: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

            var arguments = [
                "-sS",
                "-m", "120",
                "-X", method,
                "-w", "\\n%{http_code}",
                "-H", "Content-Type: \(contentType)",
                "--data-binary", "@\(fileURL.path)",
                url.absoluteString
            ]

            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerPipe = Pipe()
            if !trimmedAPIKey.isEmpty {
                arguments.append(contentsOf: ["-H", "@-"])
                process.standardInput = headerPipe
            }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.arguments = arguments

            try process.run()
            if !trimmedAPIKey.isEmpty {
                let headers = "Authorization: Bearer \(trimmedAPIKey)\nX-API-Key: \(trimmedAPIKey)\n"
                headerPipe.fileHandleForWriting.write(Data(headers.utf8))
                try? headerPipe.fileHandleForWriting.close()
            }
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorOutput, encoding: .utf8) ?? "curl exited \(process.terminationStatus)"
                throw InferenceError.badStatus(Int(process.terminationStatus), url.path, message)
            }

            guard let splitIndex = output.lastIndex(of: 10) else {
                throw InferenceError.emptyResponse
            }

            let responseBody = output[..<splitIndex]
            let statusData = output[output.index(after: splitIndex)...]
            let statusText = String(data: Data(statusData), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = Int(statusText) ?? 0
            guard (200..<300).contains(status) else {
                throw InferenceError.badStatus(status, url.path, String(data: Data(responseBody), encoding: .utf8) ?? "")
            }
            return Data(responseBody)
        }.value
    }

    private static func languageQueryItems(_ language: String?) -> [URLQueryItem] {
        let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return [] }
        return [URLQueryItem(name: "language", value: normalized)]
    }

    private static func audioContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "aif", "aiff":
            return "audio/aiff"
        case "aifc":
            return "audio/aifc"
        case "caf":
            return "audio/caf"
        case "m4a", "mp4":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            fallthrough
        default:
            return "audio/wav"
        }
    }

    private func shouldUseDirectMoondream(serverURL: String) -> Bool {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let path = url.path.lowercased()
        return path.contains("moondream") || path.hasSuffix("/query") || path.hasSuffix("/point") || path.hasSuffix("/detect")
    }

    private func moondreamPoint(prompt: String, screenshotBase64: String, serverURL: String, apiKey: String) async throws -> VisionResponse {
        let pointPayload = MoondreamPointRequest(
            image: "data:image/png;base64,\(screenshotBase64)",
            imageBase64: screenshotBase64,
            object: prompt
        )
        let pointBody = try JSONEncoder().encode(pointPayload)
        if shouldPreferDetect(for: prompt),
           let detected = try await moondreamDetect(prompt: prompt, body: pointBody, serverURL: serverURL, apiKey: apiKey) {
            return detected
        }

        do {
            let data = try await request(url: try moondreamSkillURL(from: serverURL, skill: "point"), apiKey: apiKey, method: "POST", body: pointBody)
            let response = try JSONDecoder().decode(MoondreamPointResponse.self, from: data)
            if let point = response.points.first,
               Self.isUsableVisionPoint(x: point.x, y: point.y, label: prompt) {
                return VisionResponse(x: point.x, y: point.y, confidence: nil, label: prompt)
            }
        } catch InferenceError.badStatus(let status, _, _) where [404, 405, 501].contains(status) {
        }

        if let detected = try await moondreamDetect(prompt: prompt, body: pointBody, serverURL: serverURL, apiKey: apiKey) {
            return detected
        }

        guard shouldUseMoondreamQueryFallback(serverURL: serverURL) else {
            throw InferenceError.visionTargetNotFound("Moondream point/detect did not return a usable target for \(prompt).")
        }

        let queryPayload = MoondreamQueryRequest(
            image: "data:image/png;base64,\(screenshotBase64)",
            question: """
            Where is the \(prompt)? Ground the \(prompt).
            Do not choose the Apple menu, menu bar, or top-left corner unless the target explicitly asks for them.
            """
        )
        let body = try JSONEncoder().encode(queryPayload)
        let data = try await request(url: try moondreamSkillURL(from: serverURL, skill: "query"), apiKey: apiKey, method: "POST", body: body)
        let response = try JSONDecoder().decode(MoondreamQueryResponse.self, from: data)
        return try Self.decodeVisionResponse(from: response.result, label: prompt)
    }

    private func moondreamDetect(prompt: String, body: Data, serverURL: String, apiKey: String) async throws -> VisionResponse? {
        do {
            let data = try await request(url: try moondreamSkillURL(from: serverURL, skill: "detect"), apiKey: apiKey, method: "POST", body: body)
            let response = try JSONDecoder().decode(MoondreamDetectResponse.self, from: data)
            guard let box = response.objects.first(where: { Self.isUsableVisionBox($0, label: prompt) }) else {
                return nil
            }
            let x = (box.xMin + box.xMax) / 2
            let y = (box.yMin + box.yMax) / 2
            guard Self.isUsableVisionPoint(x: x, y: y, label: prompt) else {
                return nil
            }
            return VisionResponse(x: x, y: y, confidence: nil, label: prompt)
        } catch InferenceError.badStatus(let status, _, _) where [404, 405, 501].contains(status) {
            return nil
        }
    }

    private func shouldPreferDetect(for prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return lower.contains("button") ||
            lower.contains("icon") ||
            lower.contains("toolbar") ||
            lower.contains("reload") ||
            lower.contains("refresh") ||
            lower.contains("back") ||
            lower.contains("forward")
    }

    private func shouldUseMoondreamQueryFallback(serverURL: String) -> Bool {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.path.lowercased().hasSuffix("/query")
    }

    private func moondreamSkillURL(from serverURL: String, skill: String) throws -> URL {
        guard var components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InferenceError.invalidServerURL
        }
        var parts = components.path.split(separator: "/").map(String.init)
        if ["query", "point", "detect"].contains(parts.last?.lowercased() ?? "") {
            parts.removeLast()
        }
        parts.append(skill)
        components.path = "/" + parts.joined(separator: "/")
        if components.path == "/\(skill)" {
            components.path = "/moondream/\(skill)"
        }
        guard let url = components.url else {
            throw InferenceError.invalidServerURL
        }
        return url
    }

    private static func decodeVisionResponse(from result: MoondreamQueryResult, label: String) throws -> VisionResponse {
        if let point = result.reasoning?.grounding.compactMap(\.firstPoint).first,
           isUsableVisionPoint(x: point.x, y: point.y, label: label) {
            return VisionResponse(x: point.x, y: point.y, confidence: nil, label: label)
        }

        let rawContent = result.answer
        let content = stripCodeFence(rawContent)
        if let data = content.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(VisionPoint.self, from: data),
           isUsableVisionPoint(x: parsed.x, y: parsed.y, label: label) {
            return VisionResponse(x: parsed.x, y: parsed.y, confidence: parsed.confidence, label: label)
        }

        let pattern = #""?x"?\s*[:=]\s*([0-9]*\.?[0-9]+).*"?y"?\s*[:=]\s*([0-9]*\.?[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let xRange = Range(match.range(at: 1), in: content),
              let yRange = Range(match.range(at: 2), in: content),
              let x = Double(content[xRange]),
              let y = Double(content[yRange]),
              isUsableVisionPoint(x: x, y: y, label: label) else {
            let groundingCount = result.reasoning?.grounding.count ?? 0
            throw InferenceError.visionTargetNotFound("Moondream returned answer \(content.prefix(160)) with \(groundingCount) grounding result(s).")
        }
        return VisionResponse(x: x, y: y, confidence: nil, label: label)
    }

    private static func isUsableVisionPoint(x: Double, y: Double, label: String) -> Bool {
        guard (0...1).contains(x), (0...1).contains(y) else { return false }
        let lower = label.lowercased()
        let allowsMenuBar = lower.contains("apple menu") || lower.contains("menu bar") || lower.contains("top left")
        if !allowsMenuBar, x < 0.12, y < 0.12 {
            return false
        }
        if !allowsMenuBar, y > 0.92 {
            return false
        }
        return true
    }

    private static func isUsableVisionBox(_ box: MoondreamBox, label: String) -> Bool {
        guard (0...1).contains(box.xMin),
              (0...1).contains(box.yMin),
              (0...1).contains(box.xMax),
              (0...1).contains(box.yMax),
              box.xMax > box.xMin,
              box.yMax > box.yMin else {
            return false
        }
        let width = box.xMax - box.xMin
        let height = box.yMax - box.yMin
        let lower = label.lowercased()
        let allowsLarge = lower.contains("screen") || lower.contains("window") || lower.contains("page")
        if !allowsLarge, (width > 0.8 || height > 0.8) {
            return false
        }
        if lower.contains("button") || lower.contains("icon") || lower.contains("toolbar") || lower.contains("reload") || lower.contains("refresh") {
            return width > 0.005 && height > 0.005 && width < 0.12 && height < 0.12
        }
        if lower.contains("input") || lower.contains("search") || lower.contains("field") || lower.contains("bar") {
            return width > 0.03 && height > 0.005 && height < 0.2
        }
        return true
    }

    private func openAICompatibleCommand(
        text: String,
        screenContext: String?,
        serverURL: String,
        apiKey: String,
        systemPrompt: String
    ) async throws -> CommandResponse {
        let endpoint = try openAIChatCompletionsURL(from: serverURL)
        let userContent: String
        if let screenContext,
           !screenContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userContent = """
            Screen context: \(screenContext)

            User request: \(text)
            """
        } else {
            userContent = text
        }
        let payload = OpenAIChatCompletionRequest(
            model: "local-model",
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .init(type: "json_object")
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await request(url: endpoint, apiKey: apiKey, method: "POST", body: body)
        let response = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw InferenceError.emptyResponse
        }
        return try Self.decodeCommandResponse(from: content)
    }

    private func openAICompatibleAutomationStep(request automationRequest: AutomationStepRequest, serverURL: String, apiKey: String) async throws -> AutomationStepResponse {
        let endpoint = try openAIChatCompletionsURL(from: serverURL)
        let userContent = """
        Instruction: \(automationRequest.instruction)
        Step: \(automationRequest.stepIndex) of \(automationRequest.maxSteps)
        Last action: \(automationRequest.lastActionSummary ?? "none")
        Screen context: \(automationRequest.screenContext ?? "not provided")
        """
        let payload = OpenAIChatCompletionRequest(
            model: "local-model",
            messages: [
                .init(role: "system", content: Self.automationSystemPrompt),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .init(type: "json_object")
        )
        let body = try JSONEncoder().encode(payload)
        let data = try await request(url: endpoint, apiKey: apiKey, method: "POST", body: body)
        let response = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw InferenceError.emptyResponse
        }
        return try Self.decodeAutomationStepResponse(from: content)
    }

    private func shouldTryOpenAICompatibleFallback(after error: Error) -> Bool {
        switch error {
        case InferenceError.badStatus(let status, _, _):
            // Raw llama.cpp/OpenAI-compatible servers do not expose RatRemote's /command route.
            // They may report that as 404, 400, or even 401 depending on server/auth middleware.
            return [400, 401, 404, 405].contains(status)
        default:
            return false
        }
    }

    private func openAIChatCompletionsURL(from serverURL: String) throws -> URL {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InferenceError.invalidServerURL
        }
        if url.path.hasSuffix("/chat/completions") {
            return url
        }
        return url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
    }

    private static func decodeCommandResponse(from rawContent: String) throws -> CommandResponse {
        let content = stripCodeFence(rawContent)
        let data = Data(content.utf8)
        if let response = try? JSONDecoder().decode(CommandResponse.self, from: data) {
            return response
        }

        let jsonContent = extractJSON(from: content)
        let jsonData = Data(jsonContent.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw InferenceError.emptyResponse
        }
        if let actions = object as? [[String: Any]] {
            let wrapped = try JSONSerialization.data(withJSONObject: ["actions": actions])
            return try JSONDecoder().decode(CommandResponse.self, from: wrapped)
        }
        if let dictionary = object as? [String: Any], let actions = dictionary["actions"] as? [[String: Any]] {
            let wrapped = try JSONSerialization.data(withJSONObject: ["actions": actions])
            return try JSONDecoder().decode(CommandResponse.self, from: wrapped)
        }
        throw InferenceError.emptyResponse
    }

    private static func decodeAutomationStepResponse(from rawContent: String) throws -> AutomationStepResponse {
        let content = stripCodeFence(rawContent)
        let data = Data(content.utf8)
        if let response = try? JSONDecoder().decode(AutomationStepResponse.self, from: data) {
            return response
        }

        let jsonContent = extractJSON(from: content)
        let jsonData = Data(jsonContent.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw InferenceError.emptyResponse
        }
        if let actions = object as? [[String: Any]] {
            let wrapped = try JSONSerialization.data(withJSONObject: ["actions": actions, "shouldContinue": true])
            return try JSONDecoder().decode(AutomationStepResponse.self, from: wrapped)
        }
        if let dictionary = object as? [String: Any] {
            var wrapped = dictionary
            if wrapped["actions"] == nil {
                wrapped["actions"] = []
            }
            let wrappedData = try JSONSerialization.data(withJSONObject: wrapped)
            return try JSONDecoder().decode(AutomationStepResponse.self, from: wrappedData)
        }
        throw InferenceError.emptyResponse
    }

    private static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Find the first opening bracket
        let openChar: Character
        var closeChar: Character
        if let firstOpen = trimmed.first(where: { $0 == "{" || $0 == "[" }) {
            openChar = firstOpen
            closeChar = (openChar == "{") ? "}" : "]"
        } else {
            return text
        }

        var depth = 0
        var inString = false
        var escapeNext = false
        let chars = Array(trimmed)
        var endIndex = chars.startIndex

        for i in chars.indices {
            if escapeNext {
                escapeNext = false
                continue
            }
            if chars[i] == "\\" && inString {
                escapeNext = true
                continue
            }
            if chars[i] == "\"" && !escapeNext {
                inString.toggle()
                continue
            }
            if inString { continue }
            if chars[i] == openChar { depth += 1 }
            if chars[i] == closeChar {
                depth -= 1
                if depth == 0 {
                    endIndex = chars.index(after: i)
                    return String(chars[..<endIndex])
                }
            }
        }

        // No matching close bracket found; return original
        return text
    }

    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static let commandSystemPrompt = """
    Convert the user's spoken Mac computer-use request into JSON only.
    Schema: {"actions":[{"type":"key_press|paste_text|open_url|open_app|click|locate_and_click|close_window|quit_app|wait|scroll|swipe|run_applescript","text":string,"key":string,"modifiers":[string],"url":string,"x":number,"y":number,"amount":number}]}.
    For known web destinations, prefer open_url over visual clicking. Examples: YouTube home https://www.youtube.com, YouTube subscriptions https://www.youtube.com/feed/subscriptions, YouTube history https://www.youtube.com/feed/history, YouTube library https://www.youtube.com/feed/you, YouTube trending https://www.youtube.com/feed/trending.
    Prefer keyboard tools over visual clicking for common app/browser commands: close tab command+w, new tab command+t, reopen tab command+shift+t, refresh/reload command+r, back command+left, forward command+right, address bar command+l, find command+f, save command+s, copy command+c, paste command+v, undo command+z, redo command+shift+z.
    Use close_window for close requests and quit_app for quit or exit requests. Set text to the app name for named-app requests like close Codex. Do not use locate_and_click for close, quit, or exit.
    Use locate_and_click with text set to a concise visual target description when the request asks to click, press, select, focus, or open something visible on screen by name. For webpage search bars and fields, describe the page control, not the browser address bar. When the user names a website or app context for a visible control, use the current screen if it is already there; otherwise open or activate that context, wait, then locate the control. If you navigate before visual targeting, add wait with amount 2 before locate_and_click.
    Use swipe with text set to left, right, up, or down for touch-style app gestures. Set x and y to normalized screen coordinates only when the start point is clear.
    Use paste_text for dictating literal text. Use key names like escape, return, tab, left, right, up, down, or single letters. Use modifier names command, control, option, shift.
    """

    private static let onDeviceCommandSystemPrompt = """
    Convert the user's spoken Mac computer-control request into JSON only.
    Schema: {"actions":[{"type":"key_press|paste_text|open_url|open_app|locate_and_click|close_window|quit_app|wait|scroll|swipe","text":string,"key":string,"modifiers":[string],"url":string,"x":number,"y":number,"amount":number}],"spokenSummary":string}.
    Return at most four actions. Return an empty actions array when the request is not a computer-control instruction or is ambiguous.
    Prefer key_press for standard shortcuts, open_url for known complete HTTP/HTTPS destinations, open_app for named Mac applications, and paste_text for literal dictated text.
    Use locate_and_click only for a concise named visible interface target. Never emit scripts, shell commands, raw coordinate clicks, mouse movement, file URLs, or invented URLs. Use only the modifiers command, control, option, and shift.
    """

    private static let automationSystemPrompt = """
    You are the planner for a Mac computer-use automation loop. Return JSON only.
    Schema: {"actions":[{"type":"key_press|paste_text|open_url|open_app|click|locate_and_click|close_window|quit_app|wait|scroll|swipe","text":string,"key":string,"modifiers":[string],"url":string,"x":number,"y":number,"amount":number}],"spokenSummary":string,"criteriaSummary":string,"shouldContinue":boolean,"requiresApproval":boolean,"safetyNote":string}.
    Plan exactly one small next step from the current screenshot/context. Return at most two actions, where the second action may be wait.
    If the instruction contains visual criteria, decompose them into an explicit checklist before choosing an action. Put the checklist in criteriaSummary.
    Prefer locate_and_click for visible targets and swipe with text left/right/up/down for touch gestures. For swipe, optional x/y are normalized screen start coordinates; amount is a 0.05-0.85 screen/window fraction.
    Set shouldContinue true only when another observe-plan-act step is needed after these actions. Set shouldContinue false when the task is complete, blocked, ambiguous, or needs user review.
    Set requiresApproval true before actions that send messages, post/share/comment, purchase, delete, or run scripts.
    """
}

private struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let responseFormat: OpenAIResponseFormat

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

private struct OpenAIChatMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIResponseFormat: Encodable {
    let type: String
}

private struct OpenAIChatCompletionResponse: Decodable {
    let choices: [OpenAIChatChoice]
}

private struct OpenAIChatChoice: Decodable {
    let message: OpenAIChatResponseMessage
}

private struct OpenAIChatResponseMessage: Decodable {
    let content: String
}

private struct MoondreamQueryRequest: Encodable {
    let image: String
    let question: String
}

private struct MoondreamPointRequest: Encodable {
    let image: String
    let imageBase64: String
    let object: String
}

private struct MoondreamPointResponse: Decodable {
    let points: [VisionPoint]
}

private struct MoondreamDetectResponse: Decodable {
    let objects: [MoondreamBox]
}

private struct MoondreamBox: Decodable {
    let xMin: Double
    let yMin: Double
    let xMax: Double
    let yMax: Double

    enum CodingKeys: String, CodingKey {
        case xMin = "x_min"
        case yMin = "y_min"
        case xMax = "x_max"
        case yMax = "y_max"
    }
}

private struct MoondreamQueryResponse: Decodable {
    let result: MoondreamQueryResult
}

private struct MoondreamQueryResult: Decodable {
    let answer: String
    let reasoning: MoondreamReasoning?
}

private struct MoondreamReasoning: Decodable {
    let grounding: [MoondreamGrounding]
}

private struct MoondreamGrounding: Decodable {
    let points: [[Double]]

    var firstPoint: VisionPoint? {
        guard let point = points.first, point.count >= 2 else { return nil }
        return VisionPoint(x: point[0], y: point[1], confidence: nil)
    }
}

private struct VisionPoint: Decodable {
    let x: Double
    let y: Double
    let confidence: Double?
}
