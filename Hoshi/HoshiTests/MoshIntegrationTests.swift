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

        let server = Server(
            name: "Integration",
            hostname: host,
            username: user,
            authMethod: .password,
            useMosh: true
        )

        let session = await MainActor.run { MoshSession(server: server) }

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
