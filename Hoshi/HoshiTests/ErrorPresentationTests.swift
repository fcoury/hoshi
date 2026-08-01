import Citadel
import Crypto
import Foundation
import LocalAuthentication
import Network
import NIOCore
import Security
import XCTest
@testable import Hoshi

@MainActor
final class ErrorPresentationTests: XCTestCase {
    // MARK: - Authentication and the observed Citadel error 4

    func testPasswordAuthenticationFailureExplainsBothSupportedPossibilities() {
        let error = ErrorPresentation.classify(
            SSHClientError.allAuthenticationOptionsFailed,
            context: context(authentication: .password)
        )

        XCTAssertEqual(error.title, "Password Authentication Failed")
        XCTAssertTrue(error.explanation.contains("rejected"))
        XCTAssertTrue(error.explanation.contains("or does not allow"))
        XCTAssertTrue(error.recoverySuggestion?.contains("authorized SSH key") == true)
        XCTAssertFalse(error.explanation.contains("does not accept passwords"))
    }

    func testSelectedSSHKeyFailureDoesNotBlameThePassword() {
        let error = ErrorPresentation.classify(
            SSHClientError.allAuthenticationOptionsFailed,
            context: context(authentication: .key)
        )

        XCTAssertEqual(error.title, "SSH Key Was Not Accepted")
        XCTAssertTrue(error.recoverySuggestion?.contains("authorized_keys") == true)
        XCTAssertTrue(error.recoverySuggestion?.contains("Ed25519") == true)
        XCTAssertFalse(error.recoverySuggestion?.contains("password") == true)
    }

    func testUnknownAuthenticationMethodStaysNoncommittal() {
        let error = ErrorPresentation.classify(SSHClientError.allAuthenticationOptionsFailed)

        XCTAssertEqual(error.title, "SSH Authentication Failed")
        XCTAssertTrue(error.explanation.contains("all authentication methods"))
    }

    func testCitadelAuthenticationFailurePreservesExactOriginalTypeDomainCodeAndMessage() {
        let original = SSHClientError.allAuthenticationOptionsFailed
        let bridged = original as NSError
        let presentation = ErrorPresentation.classify(original, context: context(authentication: .password))

        XCTAssertEqual(presentation.diagnostics.errorType, "Citadel.SSHClientError")
        XCTAssertEqual(presentation.diagnostics.exactError, "Citadel.SSHClientError.allAuthenticationOptionsFailed")
        XCTAssertEqual(presentation.diagnostics.domain, "Citadel.SSHClientError")
        XCTAssertEqual(presentation.diagnostics.code, 4)
        XCTAssertEqual(presentation.diagnostics.originalMessage, bridged.localizedDescription)
        XCTAssertTrue(presentation.fullMessage.contains("Citadel.SSHClientError.allAuthenticationOptionsFailed"))
        XCTAssertTrue(presentation.fullMessage.contains("Code: 4"))
        XCTAssertTrue(presentation.fullMessage.contains("Original message:"))
    }

    func testUnsupportedPasswordAuthenticationIsStatedOnlyWhenProven() {
        let presentation = ErrorPresentation.classify(
            SSHClientError.unsupportedPasswordAuthentication,
            context: context(authentication: .password)
        )

        XCTAssertEqual(presentation.title, "This Server Does Not Accept Passwords")
        XCTAssertTrue(presentation.diagnostics.exactError.contains("unsupportedPasswordAuthentication"))
        XCTAssertTrue(presentation.recoverySuggestion?.contains("SSH Key") == true)
    }

    func testUnsupportedPublicKeyAuthenticationIsSpecific() {
        let presentation = ErrorPresentation.classify(
            SSHClientError.unsupportedPrivateKeyAuthentication,
            context: context(authentication: .key)
        )

        XCTAssertEqual(presentation.title, "This Server Does Not Accept SSH Keys")
        XCTAssertTrue(presentation.diagnostics.exactError.contains("unsupportedPrivateKeyAuthentication"))
    }

    func testUnsupportedHostBasedAuthenticationIsSpecific() {
        let presentation = ErrorPresentation.classify(SSHClientError.unsupportedHostBasedAuthentication)

        XCTAssertEqual(presentation.title, "SSH Authentication Method Unsupported")
        XCTAssertTrue(presentation.diagnostics.exactError.contains("unsupportedHostBasedAuthentication"))
    }

    func testCitadelChannelFailureRecommendsSessionDiagnostics() {
        let presentation = ErrorPresentation.classify(SSHClientError.channelCreationFailed)

        XCTAssertEqual(presentation.title, "SSH Session Could Not Start")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("session limits") == true)
    }

    func testMissingPasswordIsDifferentFromRejectedPassword() {
        let presentation = ErrorPresentation.classify(
            SSHConnectionError.passwordNotFound,
            context: context(authentication: .password)
        )

        XCTAssertEqual(presentation.title, "Saved SSH Password Is Missing")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("enter its password again") == true)
    }

    func testMissingKeyRecommendsFreshHoshiEd25519KeyWithoutImport() {
        let presentation = ErrorPresentation.classify(
            SSHConnectionError.keyNotFound,
            context: context(authentication: .key)
        )

        XCTAssertEqual(presentation.title, "Saved SSH Key Is Unavailable")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("fresh Ed25519") == true)
        XCTAssertTrue(presentation.recoverySuggestion?.contains("authorized_keys") == true)
        XCTAssertFalse(presentation.recoverySuggestion?.localizedCaseInsensitiveContains("import") == true)
    }

    func testInvalidOpenSSHKeyRecommendsGeneratedHoshiKeyWithoutPrivateKeyPicker() {
        do {
            _ = try Curve25519.Signing.PrivateKey(sshEd25519: "not an OpenSSH private key")
            XCTFail("Expected invalid OpenSSH data to fail validation")
        } catch {
            let presentation = ErrorPresentation.classify(
                error,
                context: ErrorContext(operation: .keyValidation)
            )

            XCTAssertEqual(presentation.title, "Invalid OpenSSH Private Key")
            XCTAssertTrue(presentation.recoverySuggestion?.contains("fresh Ed25519 key in Hoshi") == true)
            XCTAssertTrue(presentation.recoverySuggestion?.contains("authorized_keys") == true)
            XCTAssertFalse(presentation.recoverySuggestion?.localizedCaseInsensitiveContains("choose") == true)
            XCTAssertFalse(presentation.recoverySuggestion?.localizedCaseInsensitiveContains("import") == true)
        }
    }

    func testMissingPasswordFailsBeforeCreatingAuthenticationMethod() {
        let server = makeServer(authentication: .password)

        XCTAssertThrowsError(try SSHConnectionService.authenticationMethod(
            server: server,
            password: nil,
            privateKeyTag: nil
        )) { error in
            guard case SSHConnectionError.passwordNotFound = error else {
                return XCTFail("Expected missing password, got \(error)")
            }
        }
    }

    func testConnectionViewModelRetainsTypedAuthenticationFailureAndContext() {
        let server = makeServer(authentication: .password)
        let viewModel = ConnectionViewModel()

        viewModel.presentConnectionError(SSHClientError.allAuthenticationOptionsFailed, server: server)

        XCTAssertTrue(viewModel.showError)
        XCTAssertEqual(viewModel.presentedError?.title, "Password Authentication Failed")
        XCTAssertEqual(viewModel.presentedError?.diagnostics.code, 4)
        XCTAssertEqual(viewModel.presentedError?.context.endpoint, "localhost:2222")
        XCTAssertEqual(viewModel.errorMessage, viewModel.presentedError?.explanation)
    }

    // MARK: - Host identity and endpoint formatting

    func testChangedHostKeyPreservesBothFingerprints() {
        let expected = "SHA256:expectedFingerprint"
        let presented = "SHA256:presentedFingerprint"
        let error = SSHHostKeyTrustError.changed(
            hostname: "localhost",
            port: 2222,
            expectedFingerprint: expected,
            presentedFingerprint: presented
        )

        let presentation = ErrorPresentation.classify(error, context: context())

        XCTAssertEqual(presentation.title, "Security Warning: SSH Host Key Changed")
        XCTAssertTrue(presentation.explanation.contains(expected))
        XCTAssertTrue(presentation.explanation.contains(presented))
        XCTAssertTrue(presentation.diagnostics.originalMessage.contains(expected))
        XCTAssertTrue(presentation.recoverySuggestion?.contains("Do not connect") == true)
    }

    func testInvalidTrustedHostKeySuggestsSecureStorageRecovery() {
        let error = SSHHostKeyTrustError.invalidStoredHostKey(hostname: "localhost", port: 2222)
        let presentation = ErrorPresentation.classify(error, context: context())

        XCTAssertEqual(presentation.title, "Trusted SSH Key Could Not Be Read")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("Keychain") == true)
    }

    func testContextFormatsLocalhostPortWithoutLocaleGrouping() {
        let presentation = ErrorPresentation.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)),
            context: context()
        )

        XCTAssertEqual(presentation.context.endpoint, "localhost:2222")
        XCTAssertTrue(presentation.explanation.contains("localhost:2222"))
        XCTAssertTrue(presentation.technicalDetails.contains("Endpoint: localhost:2222"))
        XCTAssertFalse(presentation.fullMessage.contains("2.222"))
        XCTAssertFalse(presentation.fullMessage.contains("2,222"))
    }

    func testPhysicalDeviceLocalhostRecoveryExplainsDeviceScope() {
        let presentation = ErrorPresentation.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)),
            context: context()
        )

        XCTAssertTrue(presentation.recoverySuggestion?.contains("physical iPhone or iPad") == true)
        XCTAssertTrue(presentation.recoverySuggestion?.contains("computer's network address") == true)
    }

    func testRemoteHostDoesNotReceiveMisleadingLocalhostAdvice() {
        let presentation = ErrorPresentation.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)),
            context: ErrorContext(operation: .connection, hostname: "server.example", port: 22)
        )

        XCTAssertFalse(presentation.recoverySuggestion?.contains("physical iPhone") == true)
    }

    // MARK: - Causal preservation

    func testNSErrorRetainsOriginalDomainCodeAndLocalizedMessage() {
        let original = NSError(
            domain: "example.ssh",
            code: 93,
            userInfo: [NSLocalizedDescriptionKey: "Remote server denied this operation."]
        )
        let presentation = ErrorPresentation.classify(original, context: context())

        XCTAssertEqual(presentation.diagnostics.domain, "example.ssh")
        XCTAssertEqual(presentation.diagnostics.code, 93)
        XCTAssertEqual(presentation.diagnostics.originalMessage, "Remote server denied this operation.")
    }

    func testNSErrorRetainsNestedUnderlyingFailure() {
        let cause = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNREFUSED),
            userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
        )
        let original = NSError(
            domain: "example.wrapper",
            code: 81,
            userInfo: [NSUnderlyingErrorKey: cause]
        )

        let diagnostics = ErrorDiagnostics(error: original)

        XCTAssertEqual(diagnostics.causes.count, 1)
        XCTAssertEqual(diagnostics.causes.first?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(diagnostics.causes.first?.code, Int(ECONNREFUSED))
        XCTAssertTrue(diagnostics.formatted.contains("Cause 1:"))
    }

    func testNSErrorRetainsMultipleUnderlyingFailures() {
        let first = NSError(domain: "first", code: 1)
        let second = NSError(domain: "second", code: 2)
        let wrapper = NSError(
            domain: "wrapper",
            code: 3,
            userInfo: ["NSMultipleUnderlyingErrorsKey": [first, second]]
        )

        let diagnostics = ErrorDiagnostics(error: wrapper)

        XCTAssertEqual(diagnostics.causes.map(\.domain), ["first", "second"])
    }

    func testMoshFallbackRetainsBothTransportFailuresInOrder() {
        let fallback = ConnectionFallbackError(
            moshError: MoshUDPError.connectionFailed("UDP port was blocked"),
            sshError: SSHClientError.allAuthenticationOptionsFailed
        )
        let presentation = ErrorPresentation.classify(fallback, context: context())

        XCTAssertEqual(presentation.title, "Mosh and SSH Both Failed")
        XCTAssertEqual(presentation.diagnostics.causes.count, 2)
        XCTAssertTrue(presentation.diagnostics.causes[0].exactError.contains("connectionFailed"))
        XCTAssertTrue(presentation.diagnostics.causes[1].exactError.contains("allAuthenticationOptionsFailed"))
        XCTAssertTrue(presentation.fullMessage.contains("Cause 1:"))
        XCTAssertTrue(presentation.fullMessage.contains("Cause 2:"))
    }

    func testUnderlyingCausalDepthIsBounded() {
        var error = NSError(domain: "leaf", code: 0)
        for depth in 1...12 {
            error = NSError(domain: "level-\(depth)", code: depth, userInfo: [NSUnderlyingErrorKey: error])
        }

        let diagnostics = ErrorDiagnostics(error: error)
        var depth = 1
        var cursor = diagnostics
        while let next = cursor.causes.first {
            depth += 1
            cursor = next
        }

        XCTAssertEqual(depth, 9)
    }

    // MARK: - Secret and sensitive-content redaction

    func testUnquotedPasswordIsRedacted() {
        assertRedacted("password=hunter2", secret: "hunter2")
        assertRedacted("password: hunter2", secret: "hunter2")
    }

    func testQuotedPasswordAndSwiftAssociatedValuesAreRedacted() {
        assertRedacted(#"password="hunter2""#, secret: "hunter2")
        assertRedacted(#"password: "hunter2""#, secret: "hunter2")
        assertRedacted("password: 'hunter2'", secret: "hunter2")
    }

    func testPassphrasesAndAPIKeysAreRedacted() {
        assertRedacted("passphrase=correct-horse", secret: "correct-horse")
        assertRedacted(#"api_key: "my-api-secret""#, secret: "my-api-secret")
        assertRedacted("client-secret=top-secret", secret: "top-secret")
    }

    func testBearerHeadersAndStandaloneBearerTokensAreRedacted() {
        assertRedacted("Authorization: Bearer abc123-secret", secret: "abc123-secret")
        assertRedacted(#"authorization="Bearer abc123-secret""#, secret: "abc123-secret")
        assertRedacted("Bearer abc123-secret", secret: "abc123-secret")
    }

    func testDescriptiveBearerTokenLabelsAreNotMistakenForSecrets() {
        let original = "Update or regenerate the companion bearer token and retry."

        XCTAssertEqual(ErrorRedactor.redact(original), original)
    }

    func testQuotedAndUnquotedTokensAreRedacted() {
        assertRedacted("token=abc123-secret", secret: "abc123-secret")
        assertRedacted(#"token: "abc123-secret""#, secret: "abc123-secret")
        assertRedacted("access_token: 'abc123-secret'", secret: "abc123-secret")
        assertRedacted("refresh-token=abc123-secret", secret: "abc123-secret")
    }

    func testQueryStringCredentialsAreRedactedWithoutDiscardingEndpoint() {
        let original = "https://example.com/events?token=abc123-secret&cursor=next"
        let sanitized = ErrorRedactor.redact(original)

        XCTAssertFalse(sanitized.contains("abc123-secret"))
        XCTAssertTrue(sanitized.contains("https://example.com/events"))
        XCTAssertTrue(sanitized.contains("cursor=next"))
    }

    func testURLUserinfoPasswordIsRedactedWithoutDiscardingHostOrUsername() {
        let sanitized = ErrorRedactor.redact("https://alice:abc123-secret@example.com/events")

        XCTAssertFalse(sanitized.contains("abc123-secret"))
        XCTAssertTrue(sanitized.contains("alice:"))
        XCTAssertTrue(sanitized.contains("@example.com"))
    }

    func testMultilinePEMPrivateKeysAreCompletelyRemoved() {
        let secret = "very-private-key-payload"
        let original = """
        failed to parse:
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(secret)
        more-secret-data
        -----END OPENSSH PRIVATE KEY-----
        """

        let sanitized = ErrorRedactor.redact(original)

        XCTAssertFalse(sanitized.contains(secret))
        XCTAssertFalse(sanitized.contains("more-secret-data"))
        XCTAssertTrue(sanitized.contains("[REDACTED PRIVATE KEY]"))
    }

    func testClipboardVoiceAndFileContentsAreRedacted() {
        assertRedacted(#"clipboard="confidential-clipboard""#, secret: "confidential-clipboard")
        assertRedacted(#"transcript: "confidential-prompt""#, secret: "confidential-prompt")
        assertRedacted(#"file_contents="confidential-document""#, secret: "confidential-document")
    }

    func testDiagnosticMessagesRedactSecretsInOuterAndNestedErrors() {
        let cause = NSError(
            domain: "nested",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: #"authorization: "Bearer nested-secret""#]
        )
        let outer = NSError(
            domain: "wrapper",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: #"password="outer-secret""#,
                NSUnderlyingErrorKey: cause,
            ]
        )

        let presentation = ErrorPresentation.classify(outer, context: context())

        XCTAssertFalse(presentation.fullMessage.contains("outer-secret"))
        XCTAssertFalse(presentation.fullMessage.contains("nested-secret"))
        XCTAssertTrue(presentation.fullMessage.contains("[REDACTED]"))
    }

    func testFingerprintsHostsPortsAndAuthenticationLabelsRemainVisible() {
        let input = "host=localhost:2222 auth=password fingerprint=SHA256:abc123 token=secret"
        let sanitized = ErrorRedactor.redact(input)

        XCTAssertTrue(sanitized.contains("localhost:2222"))
        XCTAssertTrue(sanitized.contains("auth=password"))
        XCTAssertTrue(sanitized.contains("SHA256:abc123"))
        XCTAssertFalse(sanitized.contains("secret"))
    }

    func testLongUnicodeDiagnosticsAreBoundedWithoutBreakingCharacters() {
        let original = String(repeating: "星", count: 2_000)
        let sanitized = ErrorRedactor.redact(original)

        XCTAssertTrue(sanitized.hasSuffix("… [truncated]"))
        let content = sanitized.replacingOccurrences(of: "… [truncated]", with: "")
        XCTAssertLessThanOrEqual(content.utf8.count, 4_096)
        XCTAssertTrue(content.allSatisfy { $0 == "星" })
    }

    // MARK: - Network, DNS, rate limiting, and cancellation

    func testDNSFailureExplainsHostnameResolution() {
        let presentation = ErrorPresentation.classify(
            URLError(.cannotFindHost),
            context: context()
        )

        XCTAssertEqual(presentation.title, "Server Hostname Could Not Be Resolved")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("DNS") == true)
    }

    func testURLTimeoutExplainsEndpointAndRecovery() {
        let presentation = ErrorPresentation.classify(URLError(.timedOut), context: context())

        XCTAssertEqual(presentation.title, "Connection Timed Out")
        XCTAssertTrue(presentation.explanation.contains("localhost:2222"))
    }

    func testNoInternetMentionsLocalNetworkPermissions() {
        let presentation = ErrorPresentation.classify(URLError(.notConnectedToInternet), context: context())

        XCTAssertEqual(presentation.title, "Network Connection Is Unavailable")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("local-network") == true)
    }

    func testTypedNIOConnectionRefusalUsesErrnoRatherThanMessageHeuristics() {
        let nioError = NIOCore.IOError(errnoCode: ECONNREFUSED, reason: "opaque network issue")
        let presentation = ErrorPresentation.classify(nioError, context: context())

        XCTAssertEqual(presentation.title, "SSH Connection Was Refused")
        XCTAssertTrue(presentation.explanation.contains("localhost:2222"))
    }

    func testNetworkFrameworkDNSFailureHasActionableRecovery() {
        let presentation = ErrorPresentation.classify(NWError.dns(-65554), context: context())

        XCTAssertEqual(presentation.title, "Server Hostname Could Not Be Resolved")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("local-network") == true)
    }

    func testServerRateLimitBannerIsClassifiedPrecisely() {
        let error = NSError(
            domain: "server.banner",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Not allowed at this time"]
        )
        let presentation = ErrorPresentation.classify(error, context: context())

        XCTAssertEqual(presentation.title, "SSH Server Is Temporarily Refusing Connections")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("Wait briefly") == true)
    }

    func testTaskCancellationIsNotPresentedAsAnError() {
        XCTAssertFalse(ErrorPresentation.shouldPresent(CancellationError()))
    }

    func testCancelledNetworkRequestsAreNotPresentedAsErrors() {
        XCTAssertFalse(ErrorPresentation.shouldPresent(URLError(.cancelled)))
    }

    func testCancelledBiometricPromptIsNotPresentedAsAnError() {
        XCTAssertFalse(ErrorPresentation.shouldPresent(LAError(.userCancel)))
    }

    func testConnectionViewModelSuppressesIntentionalCancellation() {
        let viewModel = ConnectionViewModel()

        viewModel.presentConnectionError(CancellationError(), server: makeServer())

        XCTAssertFalse(viewModel.showError)
        XCTAssertNil(viewModel.presentedError)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCancellationInsideFallbackCannotBecomeVisibleDualTransportError() {
        let fallback = ConnectionFallbackError(
            moshError: MoshUDPError.notConnected,
            sshError: CancellationError()
        )

        XCTAssertFalse(ErrorPresentation.shouldPresent(fallback))
    }

    func testCoordinatorNeverFallsBackForAuthenticationFailures() {
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: SSHClientError.allAuthenticationOptionsFailed))
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: SSHClientError.unsupportedPasswordAuthentication))
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: SSHClientError.unsupportedPrivateKeyAuthentication))
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: SSHConnectionError.passwordNotFound))
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: SSHConnectionError.keyNotFound))
    }

    func testCoordinatorNeverFallsBackForCancellationOrHostTrustErrors() {
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: CancellationError()))
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: URLError(.cancelled)))
        XCTAssertFalse(ConnectionCoordinator.shouldFallback(after: SSHHostKeyTrustError.declined(
            hostname: "localhost",
            port: 2222
        )))
    }

    func testCoordinatorMayFallBackAfterRecoverableMoshUDPFailure() {
        XCTAssertTrue(ConnectionCoordinator.shouldFallback(after: MoshUDPError.notConnected))
    }

    func testCompanionURLSessionCancellationDoesNotSetVisiblePollingFailure() async throws {
        let suite = "hoshi.error-presentation.companion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tokens = ErrorPresentationTokenStore()
        let configuration = AgentCompanionConfiguration(defaults: defaults, tokens: tokens)
        try configuration.configure(endpoint: "https://agents.example.com/events", token: "valid-test-token-12345")

        let client = ErrorPresentationCancelledCompanionClient()
        let monitor = AgentCompanionMonitor(configuration: configuration, client: client)
        monitor.start()

        for _ in 0..<100 {
            if !monitor.isPolling { break }
            await Task.yield()
        }

        XCTAssertFalse(monitor.isPolling)
        XCTAssertNil(monitor.lastError)
        XCTAssertNil(monitor.presentedError)
    }

    // MARK: - Mosh, tmux, and transport

    func testMoshUDPTimingIncludesExactPhaseAndSeconds() {
        let original = ConnectionCoordinatorError.timedOut(phase: .udpConnection, seconds: 12)
        let presentation = ErrorPresentation.classify(original, context: context())

        XCTAssertEqual(presentation.title, "Mosh UDP Connection Timed Out")
        XCTAssertTrue(presentation.explanation.contains("12 seconds"))
        XCTAssertTrue(presentation.recoverySuggestion?.contains("UDP") == true)
        XCTAssertTrue(presentation.diagnostics.exactError.contains("udpConnection"))
    }

    func testSSHBootstrapTimeoutDoesNotClaimMoshUDPFailure() {
        let presentation = ErrorPresentation.classify(
            ConnectionCoordinatorError.timedOut(phase: .sshBootstrap, seconds: 20),
            context: context()
        )

        XCTAssertEqual(presentation.title, "Connection Timed Out")
        XCTAssertFalse(presentation.title.contains("Mosh"))
    }

    func testInvalidMoshRangeRetainsOriginalValueAndExample() {
        let presentation = ErrorPresentation.classify(
            ConnectionCoordinatorError.invalidMoshPortRange("invalid"),
            context: context()
        )

        XCTAssertEqual(presentation.title, "Invalid Mosh UDP Port Range")
        XCTAssertTrue(presentation.fullMessage.contains("invalid"))
        XCTAssertTrue(presentation.recoverySuggestion?.contains("60000:61000") == true)
    }

    func testMissingMoshServerOffersSSHAlternative() {
        let presentation = ErrorPresentation.classify(ConnectionCoordinatorError.moshUnavailable)

        XCTAssertEqual(presentation.title, "Mosh Is Not Installed")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("SSH") == true)
    }

    func testMoshCryptoFailureRetainsOriginalZlibStatus() {
        let presentation = ErrorPresentation.classify(MoshSessionError.decompressionFailed(-3))

        XCTAssertEqual(presentation.title, "Mosh Protocol Error")
        XCTAssertTrue(presentation.fullMessage.contains("-3"))
    }

    func testMoshUDPFailureSuggestsFirewallAndSSH() {
        let presentation = ErrorPresentation.classify(MoshUDPError.connectionFailed("blocked"))

        XCTAssertEqual(presentation.title, "Mosh UDP Connection Failed")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("firewall") == true)
        XCTAssertTrue(presentation.recoverySuggestion?.contains("SSH") == true)
    }

    func testMoshInstallationFailureRetainsUnderlyingRemoteFailure() {
        let presentation = ErrorPresentation.classify(
            MoshBootstrapError.installFailed(reason: "sudo: permission denied")
        )

        XCTAssertEqual(presentation.title, "Mosh Installation Failed")
        XCTAssertTrue(presentation.diagnostics.originalMessage.contains("permission denied"))
    }

    func testTmuxConfigurationFailureOffersActionableRecovery() {
        let presentation = ErrorPresentation.classify(
            TmuxConfigurationError.missingTitle,
            context: ErrorContext(operation: .tmux)
        )

        XCTAssertEqual(presentation.title, "Invalid tmux Shortcut")
        XCTAssertTrue(presentation.diagnostics.exactError.contains("missingTitle"))
    }

    // MARK: - SFTP and file uploads

    func testSFTPPermissionDeniedIsActionable() {
        let result = ErrorPresentation.classifySFTPStatus(.permissionDenied, message: "Permission denied")

        XCTAssertEqual(result.title, "Upload Permission Denied")
        XCTAssertTrue(result.recovery?.contains("writable") == true)
    }

    func testSFTPNoSuchFileExplainsMissingDestination() {
        let result = ErrorPresentation.classifySFTPStatus(.noSuchFile, message: "No such file")

        XCTAssertEqual(result.title, "Upload Destination Was Not Found")
        XCTAssertTrue(result.explanation.contains("No such file"))
    }

    func testSFTPConnectionLossRecommendsReconnect() {
        let lost = ErrorPresentation.classifySFTPStatus(.connectionLost, message: "connection dropped")
        let absent = ErrorPresentation.classifySFTPStatus(.noConnection, message: "no connection")

        XCTAssertEqual(lost.title, "Upload Connection Was Interrupted")
        XCTAssertEqual(absent.title, "Upload Connection Was Interrupted")
        XCTAssertTrue(lost.recovery?.contains("Reconnect") == true)
    }

    func testUnsupportedSFTPOperationExplainsServerSupport() {
        let result = ErrorPresentation.classifySFTPStatus(.unsupportedOperation, message: "not supported")

        XCTAssertEqual(result.title, "SFTP Operation Is Not Supported")
        XCTAssertTrue(result.explanation.contains("not supported"))
    }

    func testGenericSFTPStatusRetainsNameAndNumericCode() {
        let result = ErrorPresentation.classifySFTPStatus(.failure, message: "disk quota exceeded")

        XCTAssertEqual(result.title, "SFTP Upload Failed")
        XCTAssertTrue(result.explanation.contains("SSH_FX_FAILURE"))
        XCTAssertTrue(result.explanation.contains("(4)"))
        XCTAssertTrue(result.explanation.contains("disk quota exceeded"))
    }

    func testSFTPConnectionClosedGetsSpecificRecovery() {
        let presentation = ErrorPresentation.classify(
            SFTPError.connectionClosed,
            context: ErrorContext(operation: .upload)
        )

        XCTAssertEqual(presentation.title, "Upload Connection Was Interrupted")
        XCTAssertTrue(presentation.diagnostics.exactError.contains("connectionClosed"))
    }

    func testCitadelChannelFailureDuringUploadExplainsSFTPSubsystem() {
        let presentation = ErrorPresentation.classify(
            CitadelError.channelFailure,
            context: ErrorContext(operation: .upload)
        )

        XCTAssertEqual(presentation.title, "SFTP Subsystem Is Unavailable")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("SFTP subsystem") == true)
    }

    func testUploadTooLargePreservesExactConfiguredLimit() {
        let presentation = ErrorPresentation.classify(
            FileUploadError.fileTooLarge(maximumBytes: 100 * 1_024 * 1_024),
            context: ErrorContext(operation: .upload)
        )

        XCTAssertEqual(presentation.title, "File Exceeds Upload Limit")
        XCTAssertTrue(presentation.diagnostics.exactError.contains("104857600"))
    }

    func testUnsafeRemotePathCannotBeMistakenForNetworkFailure() {
        let presentation = ErrorPresentation.classify(
            FileUploadError.unsafeRemoteDirectory,
            context: ErrorContext(operation: .upload)
        )

        XCTAssertEqual(presentation.title, "Unsafe Upload Path Blocked")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("remote home") == true)
    }

    func testPOSIXUploadPermissionFailureIsClassifiedByErrno() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let presentation = ErrorPresentation.classify(error, context: ErrorContext(operation: .upload))

        XCTAssertEqual(presentation.title, "Upload Permission Denied")
        XCTAssertEqual(presentation.diagnostics.code, Int(EACCES))
    }

    // MARK: - Voice, biometrics, companion, and secure storage

    func testDeniedMicrophonePermissionIncludesSettingsRecovery() {
        let presentation = ErrorPresentation.classify(
            VoicePromptError.microphoneDenied,
            context: ErrorContext(operation: .voice)
        )

        XCTAssertEqual(presentation.title, "Microphone Permission Denied")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("iOS Settings") == true)
    }

    func testUnavailableOnDeviceSpeechModelNeverSuggestsCloudFallback() {
        let presentation = ErrorPresentation.classify(
            VoicePromptError.onDeviceRecognitionUnavailable,
            context: ErrorContext(operation: .voice)
        )

        XCTAssertEqual(presentation.title, "On-Device Speech Recognition Unavailable")
        XCTAssertFalse(presentation.recoverySuggestion?.localizedCaseInsensitiveContains("cloud") == true)
    }

    func testVoiceSystemFailureRetainsOriginalAudioFrameworkCause() {
        let underlying = NSError(domain: "audio.framework", code: 27, userInfo: [NSLocalizedDescriptionKey: "Input unavailable"])
        let presentation = ErrorPresentation.classify(
            VoicePromptSystemFailure(underlying: underlying),
            context: ErrorContext(operation: .voice)
        )

        XCTAssertEqual(presentation.title, "Voice Recording Could Not Start")
        XCTAssertEqual(presentation.diagnostics.causes.first?.domain, "audio.framework")
        XCTAssertEqual(presentation.diagnostics.causes.first?.code, 27)
    }

    func testVoiceSubmissionFailureIsVisibleAndRetainsTypedError() {
        let controller = VoicePromptController()

        controller.reportSubmissionError(VoicePromptError.emptyDraft)

        XCTAssertEqual(controller.presentedError?.title, "Voice Prompt Cannot Be Sent")
        XCTAssertTrue(controller.presentedError?.diagnostics.exactError.contains("emptyDraft") == true)
        XCTAssertEqual(controller.errorMessage, VoicePromptError.emptyDraft.localizedDescription)
    }

    func testBiometricLockoutRecommendsDevicePasscode() {
        let presentation = ErrorPresentation.classify(
            LAError(.biometryLockout),
            context: ErrorContext(operation: .biometrics)
        )

        XCTAssertEqual(presentation.title, "Biometric Authentication Is Locked")
        XCTAssertTrue(presentation.recoverySuggestion?.contains("passcode") == true)
    }

    func testCompanionUnauthorizedTokenShowsHTTPStatusWithoutToken() {
        let presentation = ErrorPresentation.classify(
            AgentCompanionError.httpStatus(401),
            context: ErrorContext(operation: .companion, hostname: "agents.example.com", port: 443)
        )

        XCTAssertEqual(presentation.title, "Companion Authentication Failed")
        XCTAssertTrue(presentation.explanation.contains("401"))
        XCTAssertTrue(presentation.recoverySuggestion?.contains("token") == true)
        XCTAssertTrue(presentation.technicalDetails.contains("agents.example.com:443"))
    }

    func testCompanionForbiddenTokenShowsHTTP403() {
        let presentation = ErrorPresentation.classify(AgentCompanionError.httpStatus(403))

        XCTAssertEqual(presentation.title, "Companion Authentication Failed")
        XCTAssertTrue(presentation.fullMessage.contains("403"))
    }

    func testCompanionServerFailureRetainsHTTPStatus() {
        let presentation = ErrorPresentation.classify(AgentCompanionError.httpStatus(503))

        XCTAssertEqual(presentation.title, "Companion Service Returned an Error")
        XCTAssertTrue(presentation.explanation.contains("503"))
    }

    func testCompanionProtocolMismatchRetainsExactVersion() {
        let presentation = ErrorPresentation.classify(AgentCompanionError.unsupportedVersion(9))

        XCTAssertEqual(presentation.title, "Companion Protocol Is Not Supported")
        XCTAssertTrue(presentation.fullMessage.contains("9"))
    }

    func testCompanionKeychainFailureIncludesDecodedSecurityStatus() {
        let presentation = ErrorPresentation.classify(
            AgentCompanionError.credentialStorage(errSecMissingEntitlement),
            context: ErrorContext(operation: .credentials)
        )

        XCTAssertEqual(presentation.title, "Secure Credentials Are Unavailable")
        XCTAssertTrue(presentation.explanation.contains("\(errSecMissingEntitlement)"))
    }

    func testKeychainStatusInLegacySSHErrorIsDecodedWithoutLosingOriginal() {
        let original = SSHConnectionError.keychainError(reason: "Failed to load SSH key (status: \(errSecInteractionNotAllowed))")
        let presentation = ErrorPresentation.classify(original, context: context(authentication: .key))

        XCTAssertEqual(presentation.title, "Secure Credentials Are Unavailable")
        XCTAssertTrue(presentation.explanation.contains("\(errSecInteractionNotAllowed)"))
        XCTAssertTrue(presentation.diagnostics.exactError.contains("keychainError"))
    }

    func testOSStatusNSErrorMapsToSecureCredentialRecovery() {
        let original = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement))
        let presentation = ErrorPresentation.classify(original, context: ErrorContext(operation: .credentials))

        XCTAssertEqual(presentation.title, "Secure Credentials Are Unavailable")
        XCTAssertEqual(presentation.diagnostics.code, Int(errSecMissingEntitlement))
    }

    func testDefaultOperationProvidesActionableRecoveryAndFullUnderlyingDetails() {
        let error = NSError(domain: "unknown", code: 12, userInfo: [NSLocalizedDescriptionKey: "Something unexpected happened"])
        let presentation = ErrorPresentation.classify(error)

        XCTAssertEqual(presentation.title, "Unable to Complete Action")
        XCTAssertNotNil(presentation.recoverySuggestion)
        XCTAssertTrue(presentation.fullMessage.contains("Underlying error:"))
        XCTAssertTrue(presentation.fullMessage.contains("Domain: unknown"))
        XCTAssertTrue(presentation.fullMessage.contains("Code: 12"))
    }

    // MARK: - Helpers

    private func makeServer(authentication: AuthMethod = .password) -> Server {
        Server(
            name: "Local",
            hostname: "localhost",
            port: 2222,
            username: "felipe",
            authMethod: authentication
        )
    }

    private func context(authentication: AuthMethod = .password) -> ErrorContext {
        ErrorContext.connection(server: makeServer(authentication: authentication))
    }

    private func assertRedacted(
        _ value: String,
        secret: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = ErrorRedactor.redact(value)
        XCTAssertFalse(result.contains(secret), "Secret remained in: \(result)", file: file, line: line)
        XCTAssertTrue(result.contains("[REDACTED]"), "Missing redaction marker: \(result)", file: file, line: line)
    }
}

@MainActor
private final class ErrorPresentationTokenStore: AgentCompanionTokenStoring {
    private var token: String?

    func load() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func delete() throws { token = nil }
}

private actor ErrorPresentationCancelledCompanionClient: AgentCompanionFetching {
    func fetchEvents(endpoint: URL, bearerToken: String, cursor: String?) async throws -> AgentCompanionBatch {
        throw URLError(.cancelled)
    }
}
