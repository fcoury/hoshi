import Foundation

// Actionable SSH connection errors with user-facing messages
enum SSHConnectionError: LocalizedError {
    case invalidHostname
    case connectionRefused(hostname: String, port: Int)
    case authenticationFailed(method: String)
    case timeout(hostname: String)
    case hostKeyVerificationFailed
    case networkUnreachable
    case channelOpenFailed
    case keyNotFound
    case keyGenerationFailed(reason: String)
    case keychainError(reason: String)
    case unexpected(message: String)

    // Mosh-specific errors
    case moshServerNotFound
    case moshInstallFailed(reason: String)
    case moshInstallDeclined
    case moshConnectionFailed(reason: String)
    case moshProtocolError(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidHostname:
            return "Invalid hostname"
        case .connectionRefused(let hostname, let port):
            return "Connection refused by \(hostname):\(port)"
        case .authenticationFailed(let method):
            return "Authentication failed (\(method))"
        case .timeout(let hostname):
            return "Connection to \(hostname) timed out"
        case .hostKeyVerificationFailed:
            return "Host key verification failed"
        case .networkUnreachable:
            return "Network is unreachable"
        case .channelOpenFailed:
            return "Failed to open SSH channel"
        case .keyNotFound:
            return "SSH key not found"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .keychainError(let reason):
            return "Keychain error: \(reason)"
        case .unexpected(let message):
            return message
        case .moshServerNotFound:
            return "mosh-server not found on remote host"
        case .moshInstallFailed(let reason):
            return "Failed to install mosh-server: \(reason)"
        case .moshInstallDeclined:
            return "mosh-server installation was declined"
        case .moshConnectionFailed(let reason):
            return "Mosh connection failed: \(reason)"
        case .moshProtocolError(let reason):
            return "Mosh protocol error: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidHostname:
            return "Check the hostname format. Use an IP address or domain name."
        case .connectionRefused:
            return "Verify the server is running and the port is correct. Check firewall rules."
        case .authenticationFailed(let method):
            if method == "password" {
                return "Check your password and try again."
            }
            return "Verify your SSH key is correct and authorized on the server."
        case .timeout:
            return "Check your network connection and verify the server is reachable."
        case .hostKeyVerificationFailed:
            return "The server's host key has changed. This could indicate a security issue."
        case .networkUnreachable:
            return "Check your WiFi or cellular connection."
        case .channelOpenFailed:
            return "The server may have reached its maximum number of sessions. Try again later."
        case .keyNotFound:
            return "Generate a new SSH key pair or import an existing one."
        case .keyGenerationFailed:
            return "Try generating the key again. If the problem persists, restart the app."
        case .keychainError:
            return "Check device storage and try again."
        case .unexpected:
            return "Try reconnecting. If the problem persists, check server logs."
        case .moshServerNotFound:
            return "Install mosh-server on the remote host or disable Mosh in server settings."
        case .moshInstallFailed:
            return "Try installing mosh-server manually on the remote host."
        case .moshInstallDeclined:
            return "You can connect using plain SSH or install mosh-server manually."
        case .moshConnectionFailed:
            return "Check that UDP port 60000-61000 is open on the server firewall."
        case .moshProtocolError:
            return "Try disconnecting and reconnecting. The mosh-server may need to be restarted."
        }
    }
}
