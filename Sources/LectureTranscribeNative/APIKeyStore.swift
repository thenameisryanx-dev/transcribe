import Foundation

/// The OpenAI API key: from the `OPENAI_API_KEY` environment variable, a key entered for this session, or the
/// login keychain, in that order. Each run gets it from here (see `BackendClient`).
///
/// The keychain is reached through `/usr/bin/security`, not the Security framework: keys saved by earlier versions
/// were created by that tool, so only it can read them without a "wants to access" prompt, and the app is ad-hoc
/// signed, so an "Always Allow" given to the app itself wouldn't survive the next update.
final class APIKeyStore: @unchecked Sendable {
    enum Status {
        static let fromEnvironment = "loaded from environment"
        static let fromKeychain = "loaded from system keychain"
        static let required = "required"
        static let rejected = "rejected by OpenAI"
        static let sessionOnly = "set for this session only"
        static let saved = "saved to system keychain"
    }

    struct KeyError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Runs `/usr/bin/security` with these arguments and standard input; returns its exit status and output.
    typealias SecurityTool = @Sendable (_ arguments: [String], _ input: String?) -> (status: Int32, output: String)

    let service: String
    let account: String
    private let environment: [String: String]
    private let security: SecurityTool
    private let lock = NSLock()
    private var sessionKey: String?

    init(
        service: String = "lecture-transcribe",
        account: String = "openai_api_key",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        security: @escaping SecurityTool = APIKeyStore.runSecurityTool
    ) {
        self.service = service
        self.account = account
        self.environment = environment
        self.security = security
    }

    /// Whether `key` looks like an OpenAI key.
    static func isValid(_ key: String) -> Bool {
        key.hasPrefix("sk-") && !key.contains("\n") && !key.contains("\r")
            && key == key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key to use and where it came from, or nil when there is none.
    func currentKey() -> (key: String, status: String)? {
        let fromEnvironment = (environment["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isValid(fromEnvironment) {
            return (fromEnvironment, Status.fromEnvironment)
        }
        if let sessionKey = lock.withLock({ sessionKey }) {
            return (sessionKey, Status.sessionOnly)
        }
        if let saved = loadFromKeychain(), Self.isValid(saved) {
            return (saved, Status.fromKeychain)
        }
        return nil
    }

    func loadFromKeychain() -> String? {
        let result = security(["find-generic-password", "-a", account, "-s", service, "-w"], nil)
        guard result.status == 0 else { return nil }
        let key = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func saveToKeychain(_ key: String) throws {
        let add = ["add-generic-password", "-U", "-a", account, "-s", service, "-w"]
        let result: (status: Int32, output: String)
        if key.range(of: #"^[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil {
            // `security -i` reads the command from standard input, so the key never shows up in `ps` output.
            result = security(["-i"], (add + [key]).joined(separator: " ") + "\n")
        } else {
            result = security(add + [key], nil)
        }
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw KeyError(detail.isEmpty ? "Could not save key to system keychain." : "Could not save key: \(detail)")
        }
    }

    /// Uses `key` from now on; saved in the keychain too when `save` is set.
    /// Returns the status to show.
    func setKey(_ key: String, save: Bool) throws -> String {
        guard Self.isValid(key) else {
            throw KeyError("Invalid API key format. It should start with 'sk-'.")
        }
        if save {
            try saveToKeychain(key)
        }
        lock.withLock { sessionKey = key }
        return save ? Status.saved : Status.sessionOnly
    }

    static let runSecurityTool: SecurityTool = { arguments, input in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = inputPipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        try? inputPipe.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
