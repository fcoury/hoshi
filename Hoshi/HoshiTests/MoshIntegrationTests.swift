import XCTest
@testable import Hoshi

final class MoshIntegrationTests: XCTestCase {
    func testMoshConnectAndEcho() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["HOSHI_MOSH_HOST"], !host.isEmpty,
              let user = environment["HOSHI_MOSH_USER"], !user.isEmpty,
              let password = environment["HOSHI_MOSH_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set HOSHI_MOSH_HOST, HOSHI_MOSH_USER, and HOSHI_MOSH_PASSWORD to run live Mosh integration tests.")
        }

        let session = await MainActor.run {
            MoshSession(
                server: Server(
                    name: "Integration",
                    hostname: host,
                    username: user,
                    authMethod: .password,
                    useMosh: true
                )
            )
        }

        let marker = "__HOSHI_MOSH_OK__"
        actor OutputCollector {
            var buffer = ""
            func append(_ text: String) { buffer.append(text) }
            func contains(_ marker: String) -> Bool { buffer.contains(marker) }
            func snapshot() -> String { buffer }
        }
        let collector = OutputCollector()

        await MainActor.run {
            session.onDataReceived = { bytes in
                if let text = String(bytes: bytes, encoding: .utf8) {
                    Task {
                        await collector.append(text)
                    }
                }
            }
        }

        await session.connect(password: password)

        try await waitFor(description: "mosh connected", timeoutSeconds: 30) {
            await MainActor.run {
                session.connectionState == .connected
            }
        }

        // Prime the remote shell and allow initial prompt data to arrive.
        await session.sendString("\n")
        try? await Task.sleep(for: .seconds(1))

        await session.sendString("echo \(marker)\n")

        let markerDeadline = Date().addingTimeInterval(20)
        var sawMarker = false
        while Date() < markerDeadline {
            if await collector.contains(marker) {
                sawMarker = true
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        if !sawMarker {
            let output = await collector.snapshot()
            let state = await MainActor.run { session.connectionState }
            let stats = await MainActor.run { session.debugStats }
            XCTFail("Timed out waiting for echo marker. state=\(state), stats=\(stats), output=\(output)")
        }

        await session.disconnect()
    }

    /// Drives a mosh-server that is already running (started with `mosh-server new`),
    /// skipping the SSH bootstrap. The remote program must print `__SCENARIO_DONE__` after
    /// reading one line of input. Set HOSHI_MOSH_CAPTURE to a file path to save every chunk
    /// handed to the terminal (one base64 line per chunk) for offline screen checks.
    func testLocalMoshServerScenario() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portString = environment["HOSHI_MOSH_LOCAL_PORT"], let port = UInt16(portString),
              let keyString = environment["HOSHI_MOSH_LOCAL_KEY"],
              let key = MoshBootstrapService.decodeMoshSessionKey(keyString) else {
            throw XCTSkip("Set HOSHI_MOSH_LOCAL_PORT and HOSHI_MOSH_LOCAL_KEY to drive a running mosh-server.")
        }
        let info = MoshConnectionInfo(
            udpPort: port,
            sessionKey: key,
            sessionKeyBase64: keyString,
            serverIP: environment["HOSHI_MOSH_LOCAL_HOST"] ?? "127.0.0.1"
        )

        let session = await MainActor.run {
            MoshSession(server: Server(name: "Local", hostname: info.serverIP, username: "test", authMethod: .password, useMosh: true))
        }
        final class Chunks: @unchecked Sendable {
            var all: [[UInt8]] = []
            var text: String { String(decoding: all.joined(), as: UTF8.self) }
        }
        let chunks = Chunks()
        await MainActor.run {
            session.onDataReceived = { bytes in chunks.all.append(bytes) }
        }
        await session.resize(cols: 80, rows: 24)
        try await session.establishUDP(info: info, timeout: 10)

        try await waitFor(description: "prompt", timeoutSeconds: 20) {
            await MainActor.run { chunks.text.contains("prompt$") }
        }
        await session.sendString("hello\n")
        try await waitFor(description: "echoed input", timeoutSeconds: 20) {
            await MainActor.run { chunks.text.contains("__SCENARIO_DONE__") }
        }
        let text = await MainActor.run { chunks.text }
        XCTAssertTrue(text.contains("GOT:hello"), text)

        if let path = environment["HOSHI_MOSH_CAPTURE"] {
            let lines = await MainActor.run { chunks.all.map { Data($0).base64EncodedString() } }
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        await session.disconnect()
    }

    private func waitFor(
        description: String,
        timeoutSeconds: TimeInterval,
        condition: @escaping () async -> Bool
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
