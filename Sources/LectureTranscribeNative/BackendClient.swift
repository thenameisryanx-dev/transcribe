import Foundation

enum BackendStreamEvent: Sendable {
    case log(String)
    case status(String)
    case progress(Double)
    case done(String)
    case error(String)
}

struct BackendClient {
    private enum BackendError: Error, LocalizedError {
        case invalidResponse(String)
        case commandFailed(String)
        case backendScriptNotFound(String)

        var errorDescription: String? {
            switch self {
            case let .invalidResponse(message):
                return message
            case let .commandFailed(message):
                return message
            case let .backendScriptNotFound(message):
                return message
            }
        }
    }

    private let buildTimeRepoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BackendClient.swift
        .deletingLastPathComponent() // LectureTranscribeNative
        .deletingLastPathComponent() // Sources

    private var executableURL: URL {
        let path = CommandLine.arguments.first ?? ProcessInfo.processInfo.arguments.first ?? ""
        if path.isEmpty {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    private var pythonProgram: String {
        let env = ProcessInfo.processInfo.environment
        let override = env["TRANSCRIBE_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? "python3" : override
    }

    private func resolveBackendScriptURL() throws -> URL {
        let fileManager = FileManager.default
        let executableDirectory = executableURL.deletingLastPathComponent()
        let appResourcesDirectory = executableDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let swiftPMBundleDirectory = executableDirectory
            .appendingPathComponent("LectureTranscribeNative_LectureTranscribeNative.bundle", isDirectory: true)

        let cwdCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("transcribe_backend.py")

        let buildTimeCandidate = buildTimeRepoRoot.appendingPathComponent("transcribe_backend.py")

        let candidates: [URL] = [
            appResourcesDirectory.appendingPathComponent("python/transcribe_backend.py"),
            appResourcesDirectory.appendingPathComponent("transcribe_backend.py"),
            swiftPMBundleDirectory.appendingPathComponent("python/transcribe_backend.py"),
            cwdCandidate,
            buildTimeCandidate,
        ]

        for candidate in candidates {
            if fileManager.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let searched = candidates
            .map(\.path)
            .joined(separator: "\n")
        throw BackendError.backendScriptNotFound(
            """
            Could not locate transcribe backend script.
            Looked in:
            \(searched)
            """
        )
    }

    func fetchAPIKeyStatus() async throws -> String {
        let output = try runSimpleCommand(["key-status"])
        guard let value = output["status"] as? String else {
            throw BackendError.invalidResponse("Could not parse API key status response.")
        }
        return value
    }

    func setAPIKey(_ key: String, saveToKeychain: Bool) async throws -> String {
        var args = ["set-key", "--key", key]
        if saveToKeychain {
            args.append("--save")
        }

        let output = try runSimpleCommand(args)
        if let status = output["status"] as? String {
            return status
        }
        if let error = output["error"] as? String {
            throw BackendError.commandFailed(error)
        }
        throw BackendError.invalidResponse("Unexpected response while setting API key.")
    }

    func startTranscription(
        inputPath: String,
        outputDirectory: String,
        diarize: Bool,
        onEvent: @escaping @Sendable (BackendStreamEvent) -> Void
    ) async throws {
        var args = ["run", "--input", inputPath, "--output", outputDirectory]
        if diarize {
            args.append("--diarize")
        }

        try await runStreamCommand(args: args, onEvent: onEvent)
    }

    private func runSimpleCommand(_ args: [String]) throws -> [String: Any] {
        let backendScriptURL = try resolveBackendScriptURL()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonProgram, backendScriptURL.path] + args
        process.currentDirectoryURL = backendScriptURL.deletingLastPathComponent()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdoutText
                : stderrText
            throw BackendError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard
            let data = stdoutText.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BackendError.invalidResponse("Could not parse backend response.")
        }
        return object
    }

    private func runStreamCommand(
        args: [String],
        onEvent: @escaping @Sendable (BackendStreamEvent) -> Void
    ) async throws {
        let backendScriptURL = try resolveBackendScriptURL()
        let pythonProgram = self.pythonProgram

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            func parseAndDispatch(line: String) {
                guard
                    let data = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let kind = object["kind"] as? String
                else {
                    return
                }

                switch kind {
                case "log":
                    onEvent(.log(String(describing: object["payload"] ?? "")))
                case "status":
                    onEvent(.status(String(describing: object["payload"] ?? "")))
                case "progress":
                    let number = (object["payload"] as? NSNumber)?.doubleValue ?? 0
                    onEvent(.progress(number))
                case "done":
                    onEvent(.done(String(describing: object["payload"] ?? "")))
                case "error":
                    onEvent(.error(String(describing: object["payload"] ?? "")))
                default:
                    break
                }
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [pythonProgram, backendScriptURL.path] + args
            process.currentDirectoryURL = backendScriptURL.deletingLastPathComponent()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            let stdout = stdoutPipe.fileHandleForReading
            var textBuffer = ""
            while true {
                let data = stdout.availableData
                if data.isEmpty {
                    break
                }
                if let chunk = String(data: data, encoding: .utf8) {
                    textBuffer.append(chunk)
                    while let range = textBuffer.range(of: "\n") {
                        let line = String(textBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        textBuffer.removeSubrange(..<range.upperBound)
                        if !line.isEmpty {
                            parseAndDispatch(line: line)
                        }
                    }
                }
            }

            let trailingLine = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailingLine.isEmpty {
                parseAndDispatch(line: trailingLine)
            }

            process.waitUntilExit()
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Transcription command failed."
                    : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BackendError.commandFailed(message)
            }
        }
        .value
    }
}
