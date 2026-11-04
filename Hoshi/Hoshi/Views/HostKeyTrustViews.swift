import SwiftData
import SwiftUI

// MARK: - Verification helpers

enum HostKeyVerification {
    /// The server-side command that prints the fingerprint for a host key algorithm.
    static func verificationCommand(for algorithm: String) -> String {
        "ssh-keygen -lf /etc/ssh/\(hostKeyFile(for: algorithm))"
    }

    static func hostKeyFile(for algorithm: String) -> String {
        if algorithm.contains("ed25519") { return "ssh_host_ed25519_key.pub" }
        if algorithm.hasPrefix("ecdsa") { return "ssh_host_ecdsa_key.pub" }
        if algorithm.contains("rsa") { return "ssh_host_rsa_key.pub" }
        return "ssh_host_*_key.pub"
    }

    static func displayName(for algorithm: String) -> String {
        if algorithm.contains("ed25519") { return "ED25519" }
        if algorithm.hasPrefix("ecdsa") { return "ECDSA" }
        if algorithm.contains("rsa") { return "RSA" }
        return algorithm
    }
}

// MARK: - Trust prompt

private struct HostKeyTrustPromptModifier: ViewModifier {
    let isEnabled: Bool

    @State private var coordinator = HostKeyTrustCoordinator.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { isEnabled ? currentRequest : nil },
            set: { _ in }
        )) { request in
            HostKeyTrustSheet(
                identity: request.identity,
                replacedFingerprint: coordinator.replacedFingerprint(for: request.identity)
            ) { trusted in
                coordinator.resolve(requestID: request.id, trusted: trusted)
            }
            // A trust decision must be explicit, and hiding the sheet (e.g. the app going
            // inactive) must not count as declining, so swipe-to-dismiss is off.
            .interactiveDismissDisabled()
        }
    }

    private var currentRequest: PendingHostKeyRequest? {
        guard let id = coordinator.pendingRequestID, let identity = coordinator.pendingIdentity else { return nil }
        return PendingHostKeyRequest(id: id, identity: identity)
    }
}

private struct PendingHostKeyRequest: Identifiable {
    let id: UUID
    let identity: SSHHostKeyIdentity
}

extension View {
    func hostKeyTrustPrompt(enabled: Bool = true) -> some View {
        modifier(HostKeyTrustPromptModifier(isEnabled: enabled))
    }
}

struct HostKeyTrustSheet: View {
    let identity: SSHHostKeyIdentity
    let replacedFingerprint: String?
    let onDecision: (Bool) -> Void

    @Query private var servers: [Server]

    private var serverNames: [String] {
        servers
            .filter { $0.hostname.caseInsensitiveCompare(identity.hostname) == .orderedSame && $0.port == identity.port }
            .map(\.name)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if let replacedFingerprint {
                        FingerprintCard(
                            title: "Previously Trusted",
                            fingerprint: replacedFingerprint,
                            tint: .red,
                            struckThrough: true
                        )
                    }

                    FingerprintCard(
                        title: replacedFingerprint == nil
                            ? "\(HostKeyVerification.displayName(for: identity.algorithm)) Fingerprint"
                            : "New \(HostKeyVerification.displayName(for: identity.algorithm)) Fingerprint",
                        fingerprint: identity.fingerprint,
                        tint: replacedFingerprint == nil ? .accentColor : .orange,
                        struckThrough: false
                    )

                    verificationHint
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Verify Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDecision(false) }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: replacedFingerprint == nil ? "lock.shield" : "exclamationmark.shield")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(replacedFingerprint == nil ? Color.accentColor : .orange)

            Text(serverNames.first ?? identity.hostname)
                .font(.title2.bold())

            Text(verbatim: identity.endpoint)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)

            Text(replacedFingerprint == nil
                 ? "Hoshi hasn't connected to this server before. Check that the fingerprint below matches the server before trusting it."
                 : "You removed this server's old key. Make sure the new key is expected, for example after a server reinstall.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verificationHint: some View {
        let command = HostKeyVerification.verificationCommand(for: identity.algorithm)
        return VStack(alignment: .leading, spacing: 8) {
            Label("How to verify", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
            Text("From a session you already trust on the server, run:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Text(verbatim: command)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = command
                    HapticService.success()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy command")
            }
            .padding(10)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
            Text("The SHA256 value it prints should match the fingerprint above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                onDecision(true)
            } label: {
                Text(replacedFingerprint == nil ? "Trust and Connect" : "Trust New Key and Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(replacedFingerprint == nil ? .accentColor : .orange)
            .accessibilityIdentifier("hostkey.trust")

            Button("Don't Connect", role: .cancel) { onDecision(false) }
                .accessibilityIdentifier("hostkey.decline")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct FingerprintCard: View {
    let title: String
    let fingerprint: String
    let tint: Color
    let struckThrough: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
                Spacer()
                Button {
                    UIPasteboard.general.string = fingerprint
                    HapticService.success()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(verbatim: fingerprint)
                .font(.body.monospaced())
                .strikethrough(struckThrough)
                .foregroundStyle(struckThrough ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Known hosts

struct KnownHostsView: View {
    @Query private var servers: [Server]

    @State private var hosts: [TrustedHostKey] = []
    @State private var loadError: ErrorPresentation?
    @State private var pendingRemoval: TrustedHostKey?

    var body: some View {
        List {
            if let loadError {
                Section { ErrorPresentationView(presentation: loadError) }
            }

            if hosts.isEmpty, loadError == nil {
                ContentUnavailableView(
                    "No Trusted Hosts",
                    systemImage: "lock.shield",
                    description: Text("Servers you verify appear here.")
                )
            } else {
                Section {
                    ForEach(hosts) { host in
                        row(host)
                            .swipeActions {
                                Button("Remove", role: .destructive) { pendingRemoval = host }
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = host.identity.fingerprint
                                } label: {
                                    Label("Copy Fingerprint", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    pendingRemoval = host
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text("Removing a host makes Hoshi ask you to verify its key again on the next connection.")
                }
            }
        }
        .navigationTitle("Known Hosts")
        .onAppear(perform: reload)
        .confirmationDialog(
            "Remove Trusted Key?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { host in
            Button("Remove", role: .destructive) { remove(host) }
        } message: { host in
            Text("You'll be asked to verify \(host.identity.endpoint) the next time you connect.")
        }
    }

    private func row(_ host: TrustedHostKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(serverName(for: host) ?? host.identity.hostname)
                    .font(.headline)
                Spacer()
                Text(HostKeyVerification.displayName(for: host.identity.algorithm))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: .capsule)
            }
            Text(verbatim: host.identity.endpoint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(verbatim: host.identity.fingerprint)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let trustedAt = host.trustedAt {
                Text("Trusted \(trustedAt, format: .dateTime.year().month().day())")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func serverName(for host: TrustedHostKey) -> String? {
        servers.first {
            $0.hostname.caseInsensitiveCompare(host.identity.hostname) == .orderedSame && $0.port == host.identity.port
        }?.name
    }

    private func reload() {
        do {
            hosts = try KnownHostsService.shared.trustedHostKeys()
            loadError = nil
        } catch {
            loadError = ErrorPresentation.classify(error, context: ErrorContext(operation: .credentials))
        }
    }

    private func remove(_ host: TrustedHostKey) {
        do {
            try KnownHostsService.shared.remove(host.identity)
            HapticService.success()
            reload()
        } catch {
            loadError = ErrorPresentation.classify(error, context: ErrorContext(operation: .credentials))
        }
    }
}
