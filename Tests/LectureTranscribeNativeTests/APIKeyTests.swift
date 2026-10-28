import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Answers requests made through `StubOpenAI.session` with a fixed status, and records them.
final class StubOpenAI: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var fails = false
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubOpenAI.self]
        return URLSession(configuration: configuration)
    }

    static func reset(status: Int = 200, fails: Bool = false) {
        self.status = status
        self.fails = fails
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if Self.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The API key's status, saving and check with OpenAI.
final class APIKeyTests: XCTestCase {
    /// A stand-in for `/usr/bin/security` that keeps one saved key.
    private final class FakeKeychain: @unchecked Sendable {
        var saved: String?
        var calls: [(arguments: [String], input: String?)] = []

        var tool: APIKeyStore.SecurityTool {
            { [self] arguments, input in
                calls.append((arguments, input))
                switch arguments.first {
                case "find-generic-password":
                    return saved.map { (0, $0 + "\n") } ?? (44, "The specified item could not be found in the keychain.")
                case "-i":
                    saved = input?.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    return (0, "")
                default:
                    saved = arguments.last
                    return (0, "")
                }
            }
        }
    }

    private func backend(keychain: FakeKeychain, environment: [String: String] = [:]) -> BackendClient {
        BackendClient(
            apiKeys: APIKeyStore(environment: environment, security: keychain.tool),
            openAI: OpenAIClient(environment: [:], session: StubOpenAI.session)
        )
    }

    override func setUp() {
        StubOpenAI.reset()
    }

    func testStatusSaysWhereTheKeyComesFrom() async throws {
        let keychain = FakeKeychain()
        let none = backend(keychain: keychain)
        var status = try await none.fetchAPIKeyStatus()
        XCTAssertEqual(status, "required")

        keychain.saved = "sk-saved"
        status = try await backend(keychain: keychain).fetchAPIKeyStatus()
        XCTAssertEqual(status, "loaded from system keychain")

        status = try await backend(keychain: keychain, environment: ["OPENAI_API_KEY": "sk-env"]).fetchAPIKeyStatus()
        XCTAssertEqual(status, "loaded from environment")
    }

    func testOnlyARejectionFromOpenAIChangesTheStatus() async throws {
        let keychain = FakeKeychain()
        keychain.saved = "sk-saved"
        StubOpenAI.reset(status: 401)
        var status = try await backend(keychain: keychain).fetchAPIKeyStatus(verify: true)
        XCTAssertEqual(status, "rejected by OpenAI")
        XCTAssertEqual(StubOpenAI.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-saved")
        XCTAssertEqual(StubOpenAI.requests.first?.url?.absoluteString, "https://api.openai.com/v1/models")

        for answer in [(status: 429, fails: false), (status: 500, fails: false), (status: 200, fails: true)] {
            StubOpenAI.reset(status: answer.status, fails: answer.fails)
            status = try await backend(keychain: keychain).fetchAPIKeyStatus(verify: true)
            XCTAssertEqual(status, "loaded from system keychain", "\(answer)")
        }
    }

    func testANewKeyIsCheckedThenSavedWithoutShowingItInTheProcessList() async throws {
        let keychain = FakeKeychain()
        let client = backend(keychain: keychain)
        let status = try await client.setAPIKey("sk-new_Key-123", saveToKeychain: true)
        XCTAssertEqual(status, "saved to system keychain")
        XCTAssertEqual(keychain.saved, "sk-new_Key-123")
        let save = try XCTUnwrap(keychain.calls.first { $0.arguments.first == "-i" })
        XCTAssertEqual(save.arguments, ["-i"], "The key goes on standard input, not in the arguments")
        XCTAssertEqual(save.input, "add-generic-password -U -a openai_api_key -s lecture-transcribe -w sk-new_Key-123\n")
        XCTAssertEqual(client.apiKeys.currentKey()?.key, "sk-new_Key-123")
    }

    func testASessionKeyIsUsedButNotSaved() async throws {
        let keychain = FakeKeychain()
        keychain.saved = "sk-old"
        let client = backend(keychain: keychain)
        let status = try await client.setAPIKey("sk-session", saveToKeychain: false)
        XCTAssertEqual(status, "set for this session only")
        XCTAssertEqual(keychain.saved, "sk-old")
        XCTAssertEqual(client.apiKeys.currentKey()?.key, "sk-session")
    }

    func testBadKeysAreRefusedWithTheBackendsMessages() async {
        let keychain = FakeKeychain()
        let cases: [(key: String, status: Int, fails: Bool, message: String)] = [
            ("not-a-key", 200, false, "Invalid API key format. It should start with 'sk-'."),
            ("sk-wrong", 401, false, "OpenAI didn't accept this key. Copy it again from platform.openai.com/api-keys."),
            ("sk-offline", 200, true, "Couldn't reach OpenAI to check this key. Check your internet connection, then try again."),
        ]
        for item in cases {
            StubOpenAI.reset(status: item.status, fails: item.fails)
            do {
                _ = try await backend(keychain: keychain).setAPIKey(item.key, saveToKeychain: true)
                XCTFail("\(item.key) should be refused")
            } catch {
                XCTAssertEqual(error.localizedDescription, item.message)
            }
        }
        XCTAssertNil(keychain.saved)
    }

    func testRunsUseTheCurrentKey() async throws {
        let keychain = FakeKeychain()
        keychain.saved = "sk-saved"
        let client = backend(keychain: keychain)
        XCTAssertEqual(client.apiKeys.currentKey()?.key, "sk-saved")
        _ = try await client.setAPIKey("sk-session", saveToKeychain: false)
        XCTAssertEqual(client.apiKeys.currentKey()?.key, "sk-session")
    }

    func testOpenAIBaseURLCanPointElsewhere() {
        let client = OpenAIClient(environment: ["OPENAI_BASE_URL": "http://127.0.0.1:8765/v1"])
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:8765/v1")
    }

    /// The real `security` tool, with a throwaway keychain entry that's removed afterwards.
    func testSavingAndLoadingThroughTheRealKeychain() throws {
        let store = APIKeyStore(service: "lecture-transcribe-tests-\(UUID().uuidString)", environment: [:])
        defer { _ = APIKeyStore.runSecurityTool(["delete-generic-password", "-a", store.account, "-s", store.service], nil) }
        do {
            _ = try store.setKey("sk-test-\(UUID().uuidString.prefix(8))", save: true)
        } catch {
            throw XCTSkip("This Mac's login keychain isn't available to tests: \(error.localizedDescription)")
        }
        let saved = try XCTUnwrap(store.loadFromKeychain())
        XCTAssertTrue(saved.hasPrefix("sk-test-"))
        XCTAssertEqual(APIKeyStore(service: store.service, environment: [:]).currentKey()?.status, "loaded from system keychain")
    }
}
