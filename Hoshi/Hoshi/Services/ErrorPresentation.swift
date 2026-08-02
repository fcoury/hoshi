import Citadel
import Foundation
import LocalAuthentication
import Network
import NIOCore
import NIOPosix
import Security

/// The operation that failed. Context contains only diagnostic metadata, never credentials or content.
enum ErrorOperation: String, Equatable, Sendable {
    case connection = "SSH connection"
    case tmux = "tmux"
    case upload = "file upload"
    case fileBrowser = "remote file browser"
    case voice = "voice prompt"
    case companion = "agent companion"
    case notifications = "notifications"
    case biometrics = "device authentication"
    case credentials = "secure credentials"
    case keyValidation = "SSH key validation"
    case general = "operation"
}

struct ErrorContext: Equatable, Sendable {
    var operation: ErrorOperation = .general
    var hostname: String?
    var port: Int?
    var username: String?
    var authenticationMethod: String?
    var transport: String?
    var phase: String?

    static func connection(
        server: Server,
        phase: String? = nil,
        operation: ErrorOperation = .connection
    ) -> Self {
        Self(
            operation: operation,
            hostname: server.hostname,
            port: server.port,
            username: server.username,
            authenticationMethod: server.authMethod.rawValue,
            transport: server.transportPolicy.rawValue,
            phase: phase
        )
    }

    var endpoint: String? {
        guard let hostname else { return nil }
        guard let port else { return hostname }
        return "\(hostname):\(String(port))"
    }

    var diagnosticLines: [String] {
        var values: [String] = ["Operation: \(operation.rawValue)"]
        if let endpoint { values.append("Endpoint: \(ErrorRedactor.redact(endpoint))") }
        if let username { values.append("Username: \(ErrorRedactor.redact(username))") }
        if let authenticationMethod { values.append("Authentication: \(authenticationMethod)") }
        if let transport { values.append("Transport: \(transport)") }
        if let phase, !phase.isEmpty { values.append("Phase: \(ErrorRedactor.redact(phase))") }
        return values
    }
}

/// A bounded, sanitized copy of the original error and every explicitly provided underlying cause.
struct ErrorDiagnostics: Equatable, Sendable {
    let errorType: String
    let exactError: String
    let domain: String
    let code: Int
    let originalMessage: String
    let causes: [ErrorDiagnostics]

    init(error: any Error) {
        self = Self.capture(error, depth: 0, visited: [])
    }

    private static func capture(
        _ error: any Error,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> ErrorDiagnostics {
        let foundationError = error as NSError
        let identifier = ObjectIdentifier(foundationError)
        let exactError = ErrorRedactor.redact(String(reflecting: error))
        var seen = visited
        seen.insert(identifier)

        var underlying: [any Error] = []
        if let fallbackError = error as? ConnectionFallbackError {
            underlying.append(fallbackError.moshError)
            underlying.append(fallbackError.sshError)
        }
        if let voiceError = error as? VoicePromptSystemFailure {
            underlying.append(voiceError.underlying)
        }
        if let connectionError = error as? NIOConnectionError {
            if let dnsError = connectionError.dnsAError { underlying.append(dnsError) }
            if let dnsError = connectionError.dnsAAAAError { underlying.append(dnsError) }
            underlying.append(contentsOf: connectionError.connectionErrors.map(\.error))
        }
        if let child = foundationError.userInfo[NSUnderlyingErrorKey] as? any Error {
            underlying.append(child)
        }
        if let children = foundationError.userInfo["NSMultipleUnderlyingErrorsKey"] as? [any Error] {
            underlying.append(contentsOf: children)
        }

        let causes: [ErrorDiagnostics]
        if depth < 8 {
            causes = underlying.compactMap { child in
                let childObject = child as NSError
                guard !seen.contains(ObjectIdentifier(childObject)) else { return nil }
                return capture(child, depth: depth + 1, visited: seen)
            }
        } else {
            causes = []
        }

        return ErrorDiagnostics(
            errorType: ErrorRedactor.redact(String(reflecting: type(of: error))),
            exactError: exactError,
            domain: ErrorRedactor.redact(foundationError.domain),
            code: foundationError.code,
            originalMessage: ErrorRedactor.redact(error.localizedDescription),
            causes: causes
        )
    }

    private init(
        errorType: String,
        exactError: String,
        domain: String,
        code: Int,
        originalMessage: String,
        causes: [ErrorDiagnostics]
    ) {
        self.errorType = errorType
        self.exactError = exactError
        self.domain = domain
        self.code = code
        self.originalMessage = originalMessage
        self.causes = causes
    }

    var formatted: String {
        var lines = [
            "Underlying error: \(exactError)",
            "Type: \(errorType)",
            "Domain: \(domain)",
            "Code: \(code)",
            "Original message: \(originalMessage)",
        ]
        for (index, cause) in causes.enumerated() {
            lines.append("Cause \(index + 1):")
            lines.append(contentsOf: cause.formatted.split(separator: "\n").map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

/// Passwords, bearer tokens, authorization headers, URL credentials, and private keys never enter diagnostics.
enum ErrorRedactor {
    private static let patterns: [(String, String)] = [
        (#"(?is)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
        (#"(?im)(authorization\s*[:=]\s*)(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|bearer\s+[^\s,;\"']+|[^\s,;\"']+)"#, "$1[REDACTED]"),
        (#"(?i)((?:password|passwd|passphrase|access[_-]?token|refresh[_-]?token|token|api[_-]?key|client[_-]?secret|private[_-]?key|transcript|clipboard|file[_-]?contents?|audio[_-]?(?:data|content))\s*[:=]\s*)([\"'])([^\"'\r\n]*)([\"'])"#, "$1$2[REDACTED]$4"),
        (#"(?i)((?:[?&]|^)(?:password|passwd|passphrase|access[_-]?token|refresh[_-]?token|token|api[_-]?key|client[_-]?secret|private[_-]?key|transcript|clipboard|file[_-]?contents?)=)[^&#\s]+"#, "$1[REDACTED]"),
        (#"(?i)(bearer\s+)(?!(?:tokens?|authentication|credentials?)\b)[^\s,;\"']+"#, "$1[REDACTED]"),
        (#"(?i)((?:password|passwd|passphrase|access[_-]?token|refresh[_-]?token|token|api[_-]?key|client[_-]?secret|private[_-]?key|transcript|clipboard|file[_-]?contents?|audio[_-]?(?:data|content))\s*[:=]\s*)[^\s,;\"'&]+"#, "$1[REDACTED]"),
        (#"(?i)(https?://[^\s/@:]+:)[^\s/@]+(@)"#, "$1[REDACTED]$2"),
    ]

    static func redact(_ value: String) -> String {
        var sanitized = value
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = expression.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: replacement
            )
        }

        let limit = 4_096
        guard sanitized.utf8.count > limit else { return sanitized }
        var bounded = ""
        var byteCount = 0
        for character in sanitized {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= limit else { break }
            bounded.append(character)
            byteCount += bytes
        }
        return bounded + "… [truncated]"
    }
}

struct ErrorPresentation: Identifiable, Equatable, Sendable {
    static let freshHoshiKeyRecovery =
        "Generate a fresh Ed25519 key in Hoshi and add its public key to ~/.ssh/authorized_keys on the server."

    let id: UUID
    let title: String
    let explanation: String
    let recoverySuggestion: String?
    let diagnostics: ErrorDiagnostics
    let context: ErrorContext

    init(
        title: String,
        explanation: String,
        recoverySuggestion: String?,
        error: any Error,
        context: ErrorContext
    ) {
        self.init(
            title: title,
            explanation: explanation,
            recoverySuggestion: recoverySuggestion,
            diagnostics: ErrorDiagnostics(error: error),
            context: context
        )
    }

    init(
        title: String,
        explanation: String,
        recoverySuggestion: String?,
        diagnostics: ErrorDiagnostics,
        context: ErrorContext
    ) {
        self.id = UUID()
        self.title = title
        self.explanation = ErrorRedactor.redact(explanation)
        self.recoverySuggestion = recoverySuggestion.map(ErrorRedactor.redact)
        self.diagnostics = diagnostics
        self.context = context
    }

    var technicalDetails: String {
        (context.diagnosticLines + [diagnostics.formatted]).joined(separator: "\n")
    }

    var fullMessage: String {
        var sections = [explanation]
        if let recoverySuggestion { sections.append(recoverySuggestion) }
        sections.append(technicalDetails)
        return sections.joined(separator: "\n\n")
    }

    static func shouldPresent(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let fallback = error as? ConnectionFallbackError,
           !shouldPresent(fallback.moshError) || !shouldPresent(fallback.sshError) {
            return false
        }
        if let networkError = error as? URLError, networkError.code == .cancelled { return false }
        if let authenticationError = error as? LAError,
           [.userCancel, .appCancel, .systemCancel].contains(authenticationError.code) {
            return false
        }
        let foundationError = error as NSError
        if foundationError.domain == NSCocoaErrorDomain, foundationError.code == NSUserCancelledError {
            return false
        }
        return true
    }

    static func classify(_ error: any Error, context: ErrorContext = ErrorContext()) -> ErrorPresentation {
        let result: Classification

        if let error = error as? SSHClientError {
            result = classifySSHClient(error, context: context)
        } else if let error = error as? SSHHostKeyTrustError {
            result = classifyHostKey(error)
        } else if let error = error as? SSHConnectionError {
            result = classifySSHConnection(error, context: context)
        } else if let error = error as? ConnectionCoordinatorError {
            result = classifyCoordinator(error, context: context)
        } else if error is ConnectionFallbackError {
            result = Classification(
                title: "Mosh and SSH Both Failed",
                explanation: "The Mosh connection failed, and its SSH fallback also failed.",
                recovery: "Review both underlying failures, verify the server and credentials, then retry."
            )
        } else if let error = error as? SFTPError {
            result = classifySFTP(error)
        } else if let error = error as? FileUploadError {
            result = classifyUpload(error)
        } else if let error = error as? RemoteFileBrowserError {
            result = classifyRemoteFileBrowser(error)
        } else if let error = error as? VoicePromptError {
            result = classifyVoice(error)
        } else if let error = error as? VoicePromptSystemFailure {
            result = Classification(
                title: "Voice Recording Could Not Start",
                explanation: error.localizedDescription,
                recovery: "Check microphone access and competing audio apps, then retry."
            )
        } else if let error = error as? AgentCompanionError {
            result = classifyCompanion(error)
        } else if let error = error as? MoshBootstrapError {
            result = classifyMoshBootstrap(error)
        } else if let error = error as? MoshSessionError {
            result = Classification(
                title: "Mosh Protocol Error",
                explanation: error.localizedDescription,
                recovery: "Reconnect and verify that your server's Mosh installation is compatible."
            )
        } else if let error = error as? MoshUDPError {
            result = classifyMoshUDP(error)
        } else if let error = error as? TmuxConfigurationError {
            result = Classification(
                title: "Invalid tmux Shortcut",
                explanation: error.localizedDescription,
                recovery: "Correct the shortcut name or key sequence and try again."
            )
        } else if let error = error as? InvalidOpenSSHKey {
            result = classifyOpenSSHKey(error)
        } else if let error = error as? CitadelError {
            result = classifyCitadel(error, context: context)
        } else if error is AuthenticationFailed {
            result = authenticationFailed(context: context)
        } else if let error = error as? URLError {
            result = classifyURL(error, context: context)
        } else if let error = error as? NIOConnectionError {
            result = classifyNIOConnection(error, context: context)
        } else if let error = error as? NIOCore.IOError {
            result = classifyErrno(error.errnoCode, context: context)
                ?? Classification(
                    title: defaultTitle(for: context.operation),
                    explanation: error.localizedDescription,
                    recovery: defaultRecovery(for: context.operation)
                )
        } else if let error = error as? NWError {
            result = classifyNetworkFramework(error, context: context)
        } else if let error = error as? LAError {
            result = classifyBiometrics(error)
        } else if let resultForFoundation = classifyFoundation(error as NSError, context: context) {
            result = resultForFoundation
        } else {
            result = Classification(
                title: defaultTitle(for: context.operation),
                explanation: ErrorRedactor.redact(error.localizedDescription),
                recovery: defaultRecovery(for: context.operation)
            )
        }

        return ErrorPresentation(
            title: result.title,
            explanation: result.explanation,
            recoverySuggestion: result.recovery,
            error: error,
            context: context
        )
    }

    static func sshTransportPreferenceSaveFailure(
        _ error: any Error,
        context: ErrorContext
    ) -> ErrorPresentation {
        var context = context
        context.operation = .general
        context.transport = ConnectionTransportPolicy.ssh.rawValue
        context.phase = "Saving SSH transport preference"

        let recovery = (error as? LocalizedError)?.recoverySuggestion
            ?? "Your SSH session is still connected. Try saving the preference again."
        return ErrorPresentation(
            title: "Could Not Save SSH Preference",
            explanation: error.localizedDescription,
            recoverySuggestion: recovery,
            error: error,
            context: context
        )
    }

    private struct Classification {
        let title: String
        let explanation: String
        let recovery: String?
    }

    private static func classifySSHClient(_ error: SSHClientError, context: ErrorContext) -> Classification {
        switch error {
        case .allAuthenticationOptionsFailed:
            return authenticationFailed(context: context)
        case .unsupportedPasswordAuthentication:
            return Classification(
                title: "This Server Does Not Accept Passwords",
                explanation: "The SSH server does not support password authentication for this connection.",
                recovery: "Edit this connection, choose SSH Key, and authorize its public key on the server."
            )
        case .unsupportedPrivateKeyAuthentication:
            return Classification(
                title: "This Server Does Not Accept SSH Keys",
                explanation: "The SSH server does not support public-key authentication for this connection.",
                recovery: "Choose an authentication method supported by the server or update its SSH settings."
            )
        case .unsupportedHostBasedAuthentication:
            return Classification(
                title: "SSH Authentication Method Unsupported",
                explanation: "The server does not support the requested host-based authentication method.",
                recovery: "Use an authorized SSH key or another authentication method supported by the server."
            )
        case .channelCreationFailed:
            return Classification(
                title: "SSH Session Could Not Start",
                explanation: "SSH connected, but the server refused to open a terminal or subsystem channel.",
                recovery: "Check server session limits, account restrictions, and whether the requested subsystem is enabled."
            )
        }
    }

    private static func authenticationFailed(context: ErrorContext) -> Classification {
        if context.authenticationMethod == AuthMethod.password.rawValue {
            return Classification(
                title: "Password Authentication Failed",
                explanation: "The server rejected the configured credentials or does not allow password authentication.",
                recovery: "Verify the username and password, or edit this connection and choose an authorized SSH key."
            )
        }
        if context.authenticationMethod == AuthMethod.key.rawValue {
            return Classification(
                title: "SSH Key Was Not Accepted",
                explanation: "The server rejected the selected SSH key or configured username.",
                recovery: "Verify the username and add this public key to ~/.ssh/authorized_keys. If an RSA key is rejected, generate a fresh Ed25519 key in Hoshi."
            )
        }
        return Classification(
            title: "SSH Authentication Failed",
            explanation: "The server rejected all authentication methods offered for this connection.",
            recovery: "Verify the username, password, or selected SSH key and try again."
        )
    }

    private static func classifyHostKey(_ error: SSHHostKeyTrustError) -> Classification {
        switch error {
        case .changed(_, _, let expected, let presented):
            return Classification(
                title: "Security Warning: SSH Host Key Changed",
                explanation: "The server's trusted SSH key changed. Expected \(expected), but received \(presented).",
                recovery: "Do not connect until you independently verify the replacement fingerprint with the server administrator."
            )
        case .untrusted(let identity):
            return Classification(
                title: "Verify This SSH Server",
                explanation: "The SSH host key for \(identity.endpoint) has not been trusted yet.",
                recovery: "Compare the displayed fingerprint with a trusted source before choosing Trust."
            )
        case .declined:
            return Classification(
                title: "SSH Host Was Not Trusted",
                explanation: error.localizedDescription,
                recovery: "Reconnect and trust the server only after independently verifying its fingerprint."
            )
        case .invalidHostKey:
            return Classification(
                title: "Invalid SSH Host Key",
                explanation: error.localizedDescription,
                recovery: "Stop connecting and verify the server's SSH configuration and fingerprint."
            )
        case .invalidStoredHostKey:
            return Classification(
                title: "Trusted SSH Key Could Not Be Read",
                explanation: error.localizedDescription,
                recovery: "Unlock your device and verify that Hoshi can access its secure Keychain storage."
            )
        }
    }

    private static func classifySSHConnection(_ error: SSHConnectionError, context: ErrorContext) -> Classification {
        switch error {
        case .authenticationFailed:
            return authenticationFailed(context: context)
        case .keyNotFound:
            return Classification(
                title: "Saved SSH Key Is Unavailable",
                explanation: "The SSH key selected for this connection could not be found in the device Keychain.",
                recovery: "\(freshHoshiKeyRecovery) Select the new key for this connection."
            )
        case .passwordNotFound:
            return Classification(
                title: "Saved SSH Password Is Missing",
                explanation: "This connection no longer has a saved SSH password in the device Keychain.",
                recovery: "Edit the connection, enter its password again, and save the updated credentials."
            )
        case .keychainError(let reason):
            return keychainClassification(reason: reason, status: extractKeychainStatus(reason))
        case .connectionRefused(let hostname, let port):
            return connectionRefused(endpoint: "\(hostname):\(String(port))")
        case .timeout:
            return connectionTimedOut(context: context)
        case .networkUnreachable:
            return networkUnavailable()
        case .hostKeyVerificationFailed:
            return Classification(
                title: "SSH Host Verification Failed",
                explanation: error.localizedDescription,
                recovery: "Independently verify the host-key fingerprint before reconnecting."
            )
        case .channelOpenFailed:
            return Classification(
                title: "SSH Session Could Not Start",
                explanation: error.localizedDescription,
                recovery: "Check the server's session limits and account restrictions."
            )
        case .invalidHostname:
            return Classification(
                title: "Invalid Server Hostname",
                explanation: "The configured SSH hostname is missing or invalid.",
                recovery: "Edit the connection and enter a valid IP address or hostname."
            )
        case .moshServerNotFound:
            return moshUnavailable()
        case .moshInstallFailed, .moshInstallDeclined:
            return Classification(
                title: "Mosh Could Not Be Installed",
                explanation: error.localizedDescription,
                recovery: "Install mosh-server on the remote host, or connect using SSH instead."
            )
        case .moshConnectionFailed:
            return Classification(
                title: "Mosh Connection Failed",
                explanation: error.localizedDescription,
                recovery: "Check the server's UDP firewall and Mosh port range, or switch to SSH."
            )
        case .moshProtocolError:
            return Classification(
                title: "Mosh Protocol Error",
                explanation: error.localizedDescription,
                recovery: "Reconnect and verify that the client and server use compatible Mosh versions."
            )
        case .keyGenerationFailed:
            return Classification(
                title: "SSH Key Generation Failed",
                explanation: error.localizedDescription,
                recovery: "Try generating the key again and verify the device can access its secure storage."
            )
        case .unexpected:
            return Classification(
                title: defaultTitle(for: context.operation),
                explanation: error.localizedDescription,
                recovery: defaultRecovery(for: context.operation)
            )
        }
    }

    private static func classifyCoordinator(_ error: ConnectionCoordinatorError, context: ErrorContext) -> Classification {
        switch error {
        case .timedOut(let phase, let seconds):
            if phase == .udpConnection || phase == .moshStartup {
                return Classification(
                    title: "Mosh UDP Connection Timed Out",
                    explanation: "SSH succeeded, but Mosh did not establish its UDP connection within \(Int(seconds.rounded())) seconds.",
                    recovery: "Open the configured UDP ports in your server firewall, or connect using SSH instead."
                )
            }
            return Classification(
                title: "Connection Timed Out",
                explanation: "\(phase.statusText) did not finish within \(Int(seconds.rounded())) seconds.",
                recovery: "Verify your network, server address, firewall, and configured SSH port."
            )
        case .bootstrapUnavailable:
            return Classification(
                title: "SSH Connection Is No Longer Available",
                explanation: error.localizedDescription,
                recovery: "Reconnect to the server and retry the action."
            )
        case .invalidMoshPortRange:
            return Classification(
                title: "Invalid Mosh UDP Port Range",
                explanation: error.localizedDescription,
                recovery: "Edit the connection and use a valid port or range such as 60000:61000."
            )
        case .moshUnavailable:
            return moshUnavailable()
        case .transportFailed:
            return Classification(
                title: defaultTitle(for: context.operation),
                explanation: error.localizedDescription,
                recovery: defaultRecovery(for: context.operation)
            )
        }
    }

    private static func classifySFTP(_ error: SFTPError) -> Classification {
        switch error {
        case .errorStatus(let status):
            let result = classifySFTPStatus(status.errorCode, message: status.message)
            return Classification(
                title: result.title,
                explanation: result.explanation,
                recovery: result.recovery
            )
        case .connectionClosed, .missingResponse:
            return Classification(
                title: "Upload Connection Was Interrupted",
                explanation: "The SSH/SFTP connection closed before the file transfer finished.",
                recovery: "Reconnect to the server and retry the upload."
            )
        case .unsupportedVersion:
            return Classification(
                title: "SFTP Version Is Not Supported",
                explanation: "The server does not offer a compatible SFTP subsystem.",
                recovery: "Enable or update the SSH server's SFTP subsystem and try again."
            )
        default:
            return Classification(
                title: "SFTP Upload Failed",
                explanation: "The server could not complete the secure file-transfer request.",
                recovery: "Verify SFTP is enabled and the destination directory is writable."
            )
        }
    }

    static func classifySFTPStatus(_ code: SFTPStatusCode, message: String) -> ClassificationResult {
        switch code {
        case .permissionDenied:
            return ClassificationResult(
                title: "Upload Permission Denied",
                explanation: "The server refused access to the upload destination. \(message)",
                recovery: "Choose a writable directory inside your remote home folder."
            )
        case .noSuchFile:
            return ClassificationResult(
                title: "Upload Destination Was Not Found",
                explanation: "The remote upload directory or file no longer exists. \(message)",
                recovery: "Choose an existing home-relative directory, or allow Hoshi to create one."
            )
        case .noConnection, .connectionLost:
            return ClassificationResult(
                title: "Upload Connection Was Interrupted",
                explanation: "The SSH/SFTP connection was lost. \(message)",
                recovery: "Reconnect to the server and retry the upload."
            )
        case .unsupportedOperation:
            return ClassificationResult(
                title: "SFTP Operation Is Not Supported",
                explanation: "The server's SFTP subsystem does not support the requested transfer operation. \(message)",
                recovery: "Update the server's SFTP subsystem or choose another SSH server."
            )
        default:
            return ClassificationResult(
                title: "SFTP Upload Failed",
                explanation: "The server returned \(code.debugDescription) (\(code.rawValue)). \(message)",
                recovery: "Verify the destination, available disk space, and server permissions."
            )
        }
    }

    struct ClassificationResult: Equatable, Sendable {
        let title: String
        let explanation: String
        let recovery: String?
    }

    private static func classifyUpload(_ error: FileUploadError) -> Classification {
        switch error {
        case .disconnected, .missingCredentials:
            return Classification(title: "Upload Requires an SSH Connection", explanation: error.localizedDescription, recovery: "Reconnect with the same verified server credentials and retry.")
        case .symbolicLink, .unsafeRemoteDirectory, .invalidRemotePath:
            return Classification(title: "Unsafe Upload Path Blocked", explanation: error.localizedDescription, recovery: "Choose a regular local file and a directory contained within your remote home folder.")
        case .fileTooLarge:
            return Classification(title: "File Exceeds Upload Limit", explanation: error.localizedDescription, recovery: "Choose a smaller file and try again.")
        case .invalidRemoteDirectory:
            return Classification(title: "Invalid Upload Destination", explanation: error.localizedDescription, recovery: "Enter a relative directory without absolute paths, symlinks, or parent-directory references.")
        case .invalidSource, .emptyFilename, .noSelectedFile:
            return Classification(title: "Choose a Valid File", explanation: error.localizedDescription, recovery: "Select an accessible regular file or photo and retry.")
        case .uploadInProgress:
            return Classification(title: "Upload Already in Progress", explanation: error.localizedDescription, recovery: "Wait for the current transfer to finish, or cancel it first.")
        case .uploadFailed:
            return Classification(title: "File Upload Failed", explanation: error.localizedDescription, recovery: "Verify SFTP access and your remote destination, then retry.")
        }
    }

    private static func classifyRemoteFileBrowser(_ error: RemoteFileBrowserError) -> Classification {
        switch error {
        case .disconnected, .missingCredentials:
            Classification(
                title: "File Browser Requires an SSH Connection",
                explanation: error.localizedDescription,
                recovery: "Reconnect with the same verified server credentials and retry."
            )
        case .invalidHomeDirectory, .invalidEntryName, .unsafeRemotePath, .symbolicLink:
            Classification(
                title: "Unsafe Remote File Path Blocked",
                explanation: error.localizedDescription,
                recovery: "Choose a regular file or folder contained within your remote home directory."
            )
        case .unsupportedEntry:
            Classification(
                title: "Unsupported Remote File",
                explanation: error.localizedDescription,
                recovery: "Choose a regular file or folder instead of a device, socket, or symbolic link."
            )
        case .directoryTooLarge:
            Classification(
                title: "Remote Folder Is Too Large",
                explanation: error.localizedDescription,
                recovery: "Open a smaller subfolder or reorganize this directory on the server."
            )
        case .fileTooLarge:
            Classification(
                title: "File Exceeds Download Limit",
                explanation: error.localizedDescription,
                recovery: "Choose a smaller file or transfer it another way."
            )
        case .downloadInProgress:
            Classification(
                title: "Download Already in Progress",
                explanation: error.localizedDescription,
                recovery: "Wait for the current download to finish, or cancel it first."
            )
        case .localFileUnavailable:
            Classification(
                title: "Private Download Storage Is Unavailable",
                explanation: error.localizedDescription,
                recovery: "Check available device storage and try the download again."
            )
        }
    }

    private static func classifyVoice(_ error: VoicePromptError) -> Classification {
        switch error {
        case .microphoneDenied:
            return Classification(title: "Microphone Permission Denied", explanation: error.localizedDescription, recovery: "Open iOS Settings, choose Hoshi, and allow microphone access.")
        case .microphoneRestricted:
            return Classification(title: "Microphone Access Is Restricted", explanation: error.localizedDescription, recovery: "Check Screen Time or device-management restrictions.")
        case .speechDenied:
            return Classification(title: "Speech Recognition Permission Denied", explanation: error.localizedDescription, recovery: "Open iOS Settings, choose Hoshi, and allow speech recognition.")
        case .speechRestricted:
            return Classification(title: "Speech Recognition Is Restricted", explanation: error.localizedDescription, recovery: "Check Screen Time or device-management restrictions.")
        case .onDeviceRecognitionUnavailable:
            return Classification(title: "On-Device Speech Recognition Unavailable", explanation: error.localizedDescription, recovery: "Install the selected language's dictation model or choose another language.")
        case .recognizerUnavailable, .audioUnavailable:
            return Classification(title: "Voice Recording Could Not Start", explanation: error.localizedDescription, recovery: "Check whether another app is using the microphone, then try again.")
        case .disabled:
            return Classification(title: "Voice Prompts Are Disabled", explanation: error.localizedDescription, recovery: "Enable Voice Prompts in Hoshi Settings.")
        case .emptyDraft, .draftTooLarge, .unsafeControlCharacters:
            return Classification(title: "Voice Prompt Cannot Be Sent", explanation: error.localizedDescription, recovery: "Review and correct the prompt before inserting it into the terminal.")
        }
    }

    private static func classifyCompanion(_ error: AgentCompanionError) -> Classification {
        switch error {
        case .httpStatus(let status) where status == 401 || status == 403:
            return Classification(title: "Companion Authentication Failed", explanation: "The companion rejected this authentication token (HTTP \(status)).", recovery: "Update or regenerate the companion bearer token and save the connection again.")
        case .httpStatus(let status):
            return Classification(title: "Companion Service Returned an Error", explanation: "The companion request failed with HTTP status \(status).", recovery: "Retry the request and inspect the self-hosted companion's server logs.")
        case .missingToken, .invalidToken:
            return Classification(title: "Companion Token Is Missing or Invalid", explanation: error.localizedDescription, recovery: "Enter a valid companion authentication token and save it again.")
        case .credentialStorage(let status):
            return keychainClassification(reason: error.localizedDescription, status: status)
        case .unsupportedVersion(let version):
            return Classification(title: "Companion Protocol Is Not Supported", explanation: "The companion uses unsupported protocol version \(version).", recovery: "Update Hoshi or the companion daemon so both use the same protocol version.")
        case .invalidEndpoint, .insecureEndpoint:
            return Classification(title: "Invalid Companion Endpoint", explanation: error.localizedDescription, recovery: "Enter an HTTPS companion URL. HTTP is allowed only for localhost development.")
        case .invalidResponse, .responseTooLarge:
            return Classification(title: "Invalid Companion Response", explanation: error.localizedDescription, recovery: "Verify the companion endpoint and update the daemon if necessary.")
        }
    }

    private static func classifyMoshBootstrap(_ error: MoshBootstrapError) -> Classification {
        switch error {
        case .installFailed:
            return Classification(title: "Mosh Installation Failed", explanation: error.localizedDescription, recovery: "Install mosh-server manually on the host, or connect using SSH instead.")
        case .invalidSessionKey:
            return Classification(title: "Mosh Session Key Is Invalid", explanation: error.localizedDescription, recovery: "Update mosh-server and reconnect using a compatible client/server version.")
        case .noConnectLine:
            return Classification(title: "Mosh Server Did Not Start", explanation: error.localizedDescription, recovery: "Verify mosh-server is installed, executable, and permitted for this user.")
        case .sshCommandFailed:
            return Classification(title: "Mosh SSH Bootstrap Failed", explanation: error.localizedDescription, recovery: "Check the SSH account, server command restrictions, and Mosh installation.")
        }
    }

    private static func classifyMoshUDP(_ error: MoshUDPError) -> Classification {
        if case .noServerResponse(let host, let port, let seconds) = error {
            return Classification(
                title: "Mosh Server Is Not Responding",
                explanation: "SSH started mosh-server, but \(host):\(String(port)) did not return an authenticated UDP response within \(Int(seconds.rounded())) seconds.",
                recovery: "Allow UDP port \(String(port)) through the server and network firewalls, or connect using Auto or SSH."
            )
        }

        return Classification(
            title: "Mosh UDP Connection Failed",
            explanation: error.localizedDescription,
            recovery: "Check the server's UDP firewall and Mosh port range, or connect using SSH."
        )
    }

    private static func classifyCitadel(_ error: CitadelError, context: ErrorContext) -> Classification {
        switch error {
        case .unauthorized:
            return authenticationFailed(context: context)
        case .channelCreationFailed, .channelFailure:
            return Classification(title: context.operation == .upload ? "SFTP Subsystem Is Unavailable" : "SSH Session Could Not Start", explanation: "The SSH server refused to open the requested channel or subsystem.", recovery: context.operation == .upload ? "Enable the SFTP subsystem in the server's SSH configuration." : "Check server session limits and account restrictions.")
        case .cryptographicError, .invalidMac, .invalidSignature, .signingError:
            return Classification(title: "SSH Cryptographic Verification Failed", explanation: "SSH could not verify or process encrypted connection data.", recovery: "Reconnect and verify the server host key and supported cryptographic algorithms.")
        default:
            return Classification(title: defaultTitle(for: context.operation), explanation: error.localizedDescription, recovery: defaultRecovery(for: context.operation))
        }
    }

    private static func classifyOpenSSHKey(_ error: InvalidOpenSSHKey) -> Classification {
        let reflected = String(reflecting: error)
        if reflected.contains("invalidCheck") {
            return Classification(title: "SSH Key Passphrase Is Incorrect", explanation: "The encrypted OpenSSH key could not be unlocked with the supplied passphrase.", recovery: freshHoshiKeyRecovery)
        }
        if reflected.contains("unsupportedCipher") || reflected.contains("unsupportedKDF") {
            return Classification(title: "SSH Key Encryption Is Not Supported", explanation: "This OpenSSH key uses an encryption algorithm or key-derivation function the current client cannot parse.", recovery: "Update the client, or generate a fresh Ed25519 key in Hoshi and add its public key to ~/.ssh/authorized_keys.")
        }
        if reflected.contains("unsupportedPublicKeyType") || reflected.contains("multipleKeys") {
            return Classification(title: "SSH Key Type Is Not Supported", explanation: "The supplied OpenSSH key uses an unsupported type or contains multiple private keys.", recovery: freshHoshiKeyRecovery)
        }
        return Classification(title: "Invalid OpenSSH Private Key", explanation: "The supplied key does not have a valid supported OpenSSH private-key format.", recovery: freshHoshiKeyRecovery)
    }

    private static func classifyURL(_ error: URLError, context: ErrorContext) -> Classification {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return Classification(title: "Server Hostname Could Not Be Resolved", explanation: "The configured server hostname could not be found.", recovery: "Check the hostname, DNS settings, VPN, and network connection.")
        case .cannotConnectToHost:
            return connectionRefused(endpoint: context.endpoint)
        case .timedOut:
            return connectionTimedOut(context: context)
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
            return networkUnavailable()
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return Classification(title: "Secure Connection Could Not Be Verified", explanation: "The server's TLS certificate or secure connection could not be verified.", recovery: "Verify the server certificate, device clock, and companion HTTPS configuration.")
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return authenticationFailed(context: context)
        default:
            return Classification(title: context.operation == .companion ? "Companion Service Is Unreachable" : "Network Request Failed", explanation: error.localizedDescription, recovery: context.operation == .companion ? "Verify the companion URL, network access, and that the service is running." : "Verify your network and server configuration, then try again.")
        }
    }

    private static func classifyNIOConnection(_ error: NIOConnectionError, context: ErrorContext) -> Classification {
        if error.dnsAError != nil || error.dnsAAAAError != nil {
            return Classification(
                title: "Server Hostname Could Not Be Resolved",
                explanation: "DNS could not resolve \(error.host).",
                recovery: "Verify the hostname, DNS configuration, VPN, and network connection."
            )
        }
        for failure in error.connectionErrors {
            if let ioError = failure.error as? NIOCore.IOError,
               let classification = classifyErrno(ioError.errnoCode, context: context) {
                return classification
            }
        }
        return Classification(
            title: "SSH Connection Failed",
            explanation: "The SSH client could not connect to \(error.host):\(String(error.port)).",
            recovery: "Verify the server address, SSH port, firewall, and network reachability."
        )
    }

    private static func classifyNetworkFramework(_ error: NWError, context: ErrorContext) -> Classification {
        switch error {
        case .posix(let code):
            return classifyErrno(code.rawValue, context: context) ?? networkUnavailable()
        case .dns:
            return Classification(
                title: "Server Hostname Could Not Be Resolved",
                explanation: "The network could not resolve the configured server hostname.",
                recovery: "Check the server hostname, DNS settings, VPN, and local-network permissions."
            )
        case .tls:
            return Classification(
                title: "Secure Connection Could Not Be Verified",
                explanation: "The server's secure network connection could not be verified.",
                recovery: "Verify the server certificate, device clock, and network configuration."
            )
        default:
            return networkUnavailable()
        }
    }

    private static func classifyBiometrics(_ error: LAError) -> Classification {
        switch error.code {
        case .biometryLockout:
            return Classification(title: "Biometric Authentication Is Locked", explanation: "Face ID or Touch ID is temporarily locked after too many attempts.", recovery: "Unlock the device with its passcode, then try again.")
        case .biometryNotAvailable, .biometryNotEnrolled:
            return Classification(title: "Biometric Authentication Is Unavailable", explanation: error.localizedDescription, recovery: "Set up Face ID or Touch ID in iOS Settings, or use the device passcode.")
        case .passcodeNotSet:
            return Classification(title: "Device Passcode Is Not Set", explanation: error.localizedDescription, recovery: "Set a device passcode in iOS Settings before enabling app lock.")
        case .userCancel, .appCancel, .systemCancel:
            return Classification(title: "Authentication Was Cancelled", explanation: error.localizedDescription, recovery: "Try unlocking again when you are ready.")
        case .authenticationFailed:
            return Classification(title: "Device Authentication Failed", explanation: error.localizedDescription, recovery: "Try Face ID, Touch ID, or your device passcode again.")
        default:
            return Classification(title: "Device Authentication Failed", explanation: error.localizedDescription, recovery: "Unlock the device and try again.")
        }
    }

    private static func classifyFoundation(_ error: NSError, context: ErrorContext) -> Classification? {
        if error.domain == NSPOSIXErrorDomain {
            return classifyErrno(Int32(error.code), context: context)
        }

        if error.domain == NSOSStatusErrorDomain {
            return keychainClassification(reason: error.localizedDescription, status: OSStatus(error.code))
        }

        let reflected = String(reflecting: error)
        if reflected.contains("OpenSSH.KeyError.missingDecryptionKey") {
            return Classification(title: "SSH Key Requires a Passphrase", explanation: "This OpenSSH private key is encrypted and cannot be read without its passphrase.", recovery: freshHoshiKeyRecovery)
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("not allowed at this time")
            || message.contains("too many authentication failures")
            || message.contains("maxstartups") {
            return Classification(
                title: "SSH Server Is Temporarily Refusing Connections",
                explanation: "The SSH server temporarily rejected additional connections or authentication attempts.",
                recovery: "Wait briefly, reduce concurrent connection attempts, and check the SSH server's rate limits."
            )
        }
        return nil
    }

    private static func classifyErrno(_ code: Int32, context: ErrorContext) -> Classification? {
        switch code {
        case ECONNREFUSED:
            return connectionRefused(endpoint: context.endpoint)
        case ETIMEDOUT:
            return connectionTimedOut(context: context)
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN:
            return networkUnavailable()
        case EACCES where context.operation == .upload,
             EPERM where context.operation == .upload:
            return Classification(
                title: "Upload Permission Denied",
                explanation: "The server denied access to the upload destination.",
                recovery: "Choose a writable directory inside your remote home folder."
            )
        default:
            return nil
        }
    }

    private static func keychainClassification(reason: String, status: OSStatus?) -> Classification {
        let detail: String
        if let status {
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            detail = systemMessage.map { "\(reason) (\($0))" } ?? reason
        } else {
            detail = reason
        }
        return Classification(title: "Secure Credentials Are Unavailable", explanation: detail, recovery: "Unlock your device and verify Hoshi can access its Keychain credentials. If the problem persists, re-save the connection.")
    }

    private static func extractKeychainStatus(_ reason: String) -> OSStatus? {
        guard let range = reason.range(of: #"status:\s*-?\d+"#, options: .regularExpression) else { return nil }
        let fragment = reason[range].replacingOccurrences(of: "status:", with: "").trimmingCharacters(in: .whitespaces)
        return OSStatus(fragment)
    }

    private static func connectionRefused(endpoint: String?) -> Classification {
        let target = endpoint ?? "the server"
        var recovery = "Verify the hostname, SSH port, firewall, and that the SSH server is running."
        if target.hasPrefix("localhost:") || target.hasPrefix("127.0.0.1:") || target.hasPrefix("[::1]:") {
            recovery += " On a physical iPhone or iPad, localhost refers to the device; use your computer's network address instead."
        }
        return Classification(
            title: "SSH Connection Was Refused",
            explanation: "The connection to \(target) was refused.",
            recovery: recovery
        )
    }

    private static func connectionTimedOut(context: ErrorContext) -> Classification {
        let target = context.endpoint.map { " \($0)" } ?? ""
        return Classification(title: "Connection Timed Out", explanation: "The server\(target) did not respond before the connection timed out.", recovery: "Check your network, VPN, firewall, hostname, and SSH port.")
    }

    private static func networkUnavailable() -> Classification {
        Classification(title: "Network Connection Is Unavailable", explanation: "There is currently no usable network route to the server.", recovery: "Check Wi-Fi, cellular, VPN, local-network access, and server reachability.")
    }

    private static func moshUnavailable() -> Classification {
        Classification(title: "Mosh Is Not Installed", explanation: "The remote server does not have an available mosh-server executable.", recovery: "Install mosh-server on the remote host or connect using SSH instead.")
    }

    private static func defaultTitle(for operation: ErrorOperation) -> String {
        switch operation {
        case .connection: "Connection Failed"
        case .tmux: "tmux Action Failed"
        case .upload: "File Upload Failed"
        case .fileBrowser: "Remote File Browser Failed"
        case .voice: "Voice Prompt Failed"
        case .companion: "Agent Companion Failed"
        case .notifications: "Notifications Failed"
        case .biometrics: "Device Authentication Failed"
        case .credentials: "Secure Credentials Are Unavailable"
        case .keyValidation: "SSH Key Could Not Be Validated"
        case .general: "Unable to Complete Action"
        }
    }

    private static func defaultRecovery(for operation: ErrorOperation) -> String {
        switch operation {
        case .connection: "Verify the server address and credentials, then reconnect."
        case .tmux: "Refresh your tmux sessions and verify tmux is installed on the server."
        case .upload: "Verify the SSH connection, SFTP support, and upload destination, then retry."
        case .fileBrowser: "Verify the SSH connection, SFTP support, and remote file permissions, then retry."
        case .voice: "Check microphone and speech-recognition permissions, then retry."
        case .companion: "Verify the companion URL, authentication token, and service availability."
        case .notifications: "Check Hoshi notification permissions in iOS Settings."
        case .biometrics: "Unlock the device and verify Face ID, Touch ID, or your passcode is available."
        case .credentials: "Unlock the device and re-save your connection credentials."
        case .keyValidation: freshHoshiKeyRecovery
        case .general: "Retry the action and review the technical details if the problem persists."
        }
    }
}

/// Preserves both transport failures instead of replacing the first failure with the fallback failure.
struct ConnectionFallbackError: Error {
    let moshError: any Error
    let sshError: any Error
}

/// Bridges legacy callback APIs that expose only a message while still disclosing that limitation.
struct ErrorMessageFailure: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}
