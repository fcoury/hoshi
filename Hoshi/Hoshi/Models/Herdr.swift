import Foundation

// Herdr (https://herdr.dev) is a terminal multiplexer built around coding
// agents. Hoshi talks to it only through its CLI over the verified SSH
// connection, so nothing here requires a companion server or extra port.

/// An agent's lifecycle state as reported by `herdr agent list`.
///
/// Herdr distinguishes `done` (finished, not yet seen) from `idle` (ready and
/// seen); `blocked` means it recognized an approval or question prompt.
enum HerdrAgentStatus: String, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Needs input"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "pause.circle"
        case .working: "circle.dotted.circle"
        case .blocked: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension HerdrAgentStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Newer Herdr versions may add states; never fail the whole list.
        self = HerdrAgentStatus(rawValue: raw) ?? .unknown
    }
}

/// One agent pane inside a Herdr session.
struct HerdrAgent: Decodable, Identifiable, Equatable, Sendable {
    let paneID: String
    let agent: String
    let status: HerdrAgentStatus
    let workspaceID: String?
    let tabID: String?
    let cwd: String?
    let title: String?
    let completionSeq: Int
    let stateChangeSeq: Int
    /// Whether this pane has focus in Herdr's own UI.
    let focused: Bool

    var id: String { paneID }

    var needsAttention: Bool { status == .blocked || status == .done }

    /// "claude" → "Claude", "codex" → "Codex".
    var displayName: String {
        agent.isEmpty ? "Agent" : agent.prefix(1).uppercased() + agent.dropFirst()
    }

    var directoryName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case agent
        case status = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case cwd
        case foregroundCwd = "foreground_cwd"
        case title = "terminal_title_stripped"
        case completionSeq = "completion_seq"
        case stateChangeSeq = "state_change_seq"
        case focused
    }

    init(
        paneID: String,
        agent: String,
        status: HerdrAgentStatus,
        workspaceID: String? = nil,
        tabID: String? = nil,
        cwd: String? = nil,
        title: String? = nil,
        completionSeq: Int = 0,
        stateChangeSeq: Int = 0,
        focused: Bool = false
    ) {
        self.paneID = paneID
        self.agent = agent
        self.status = status
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.cwd = cwd
        self.title = title
        self.completionSeq = completionSeq
        self.stateChangeSeq = stateChangeSeq
        self.focused = focused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? ""
        status = try container.decodeIfPresent(HerdrAgentStatus.self, forKey: .status) ?? .unknown
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
        cwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
            ?? container.decodeIfPresent(String.self, forKey: .cwd)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        self.title = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        completionSeq = try container.decodeIfPresent(Int.self, forKey: .completionSeq) ?? 0
        stateChangeSeq = try container.decodeIfPresent(Int.self, forKey: .stateChangeSeq) ?? 0
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    }
}

/// A Herdr workspace, used to group agents the way Herdr's sidebar does.
struct HerdrWorkspace: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let number: Int?
    let focused: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case label
        case number
        case focused
    }

    init(id: String, label: String, number: Int? = nil, focused: Bool = false) {
        self.id = id
        self.label = label
        self.number = number
        self.focused = focused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
    }
}

/// What a Hoshi terminal is showing from Herdr.
enum HerdrAttachment: Codable, Equatable, Sendable {
    /// Herdr's full UI for a session.
    case session(String)
    /// A single agent pane via `herdr agent attach`.
    case agent(session: String, paneID: String)

    var sessionName: String {
        switch self {
        case .session(let name): name
        case .agent(let session, _): session
        }
    }

    var choice: TmuxChoice {
        switch self {
        case .session(let name): .herdrSession(name)
        case .agent(let session, let paneID): .herdrAgent(session: session, paneID: paneID)
        }
    }

    init?(choice: TmuxChoice) {
        switch choice {
        case .herdrSession(let name): self = .session(name)
        case .herdrAgent(let session, let paneID): self = .agent(session: session, paneID: paneID)
        default: return nil
        }
    }
}

/// A named, persistent Herdr session (Herdr's own default session is `default`).
struct HerdrSessionInfo: Identifiable, Equatable, Sendable {
    let name: String
    let isRunning: Bool
    var agents: [HerdrAgent]
    var workspaces: [HerdrWorkspace]

    init(name: String, isRunning: Bool, agents: [HerdrAgent], workspaces: [HerdrWorkspace] = []) {
        self.name = name
        self.isRunning = isRunning
        self.agents = agents
        self.workspaces = workspaces
    }

    var id: String { name }

    var attentionCount: Int {
        agents.filter(\.needsAttention).count
    }

    /// Agents grouped by workspace in Herdr's order. Agents whose workspace
    /// is unknown are collected last.
    var agentsByWorkspace: [HerdrWorkspaceGroup] {
        var groups = workspaces.compactMap { workspace -> HerdrWorkspaceGroup? in
            let members = agents.filter { $0.workspaceID == workspace.id }
            return members.isEmpty ? nil : HerdrWorkspaceGroup(workspace: workspace, agents: members)
        }
        let known = Set(workspaces.map(\.id))
        let other = agents.filter { $0.workspaceID.map { !known.contains($0) } ?? true }
        if !other.isEmpty {
            groups.append(HerdrWorkspaceGroup(workspace: HerdrWorkspace(id: "", label: "Other"), agents: other))
        }
        return groups
    }

    func agent(paneID: String) -> HerdrAgent? {
        agents.first { $0.paneID == paneID }
    }
}

struct HerdrWorkspaceGroup: Identifiable, Equatable, Sendable {
    let workspace: HerdrWorkspace
    let agents: [HerdrAgent]

    var id: String { workspace.id }
}

/// What Hoshi discovered about Herdr on the connected host.
struct HerdrInventory: Equatable, Sendable {
    /// Absolute path of the resolved `herdr` executable on the remote host.
    let executable: String
    let version: String?
    var sessions: [HerdrSessionInfo]

    var runningSessions: [HerdrSessionInfo] { sessions.filter(\.isRunning) }

    var attentionCount: Int { sessions.reduce(0) { $0 + $1.attentionCount } }

    func session(named name: String) -> HerdrSessionInfo? {
        sessions.first { $0.name == name }
    }
}

// MARK: - Discovery script and parsing

enum HerdrDiscovery {
    /// The session Hoshi suggests when starting Herdr from the phone, kept
    /// separate from a desktop's `default` session.
    static let suggestedSessionName = "hoshi"

    private static let pathMarker = "__HERDR_PATH__"
    private static let versionMarker = "__HERDR_VERSION__"
    private static let listStartMarker = "__HERDR_LIST__"
    private static let listEndMarker = "__HERDR_LIST_END__"
    private static let sessionMarker = "__HERDR_SESSION__"
    private static let workspacesMarker = "__HERDR_WORKSPACES__"
    static let notInstalledMarker = "__HERDR_NONE__"

    /// A POSIX script that resolves `herdr`, lists its sessions, and prints
    /// each running session's agents as one JSON line. One exec per refresh.
    ///
    /// SSH exec shells often lack Homebrew or user-local PATH entries, so the
    /// usual install locations are checked after `command -v`.
    static var script: String {
        """
        H=""; \
        for c in "$(command -v herdr 2>/dev/null)" /opt/homebrew/bin/herdr /usr/local/bin/herdr \
        "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" "$HOME/bin/herdr"; do \
        if [ -n "$c" ] && [ -x "$c" ]; then H="$c"; break; fi; done; \
        if [ -z "$H" ]; then echo \(notInstalledMarker); exit 0; fi; \
        echo "\(pathMarker)$H"; \
        echo "\(versionMarker)$("$H" --version 2>/dev/null | head -n 1)"; \
        echo \(listStartMarker); "$H" session list 2>/dev/null; echo \(listEndMarker); \
        "$H" session list 2>/dev/null | awk 'NR > 1 && $2 == "running" { print $1 }' | \
        while read -r s; do echo "\(sessionMarker)$s"; "$H" --session "$s" agent list 2>/dev/null; echo; \
        echo "\(workspacesMarker)$s"; "$H" --session "$s" workspace list 2>/dev/null; echo; done; \
        exit 0
        """
    }

    /// The remote command that runs `script` in a login POSIX shell, whatever
    /// the user's login shell is (bash, zsh or fish).
    static var remoteCommand: String {
        "sh -lc \(HerdrCommand.quote(script)) 2>/dev/null"
    }

    /// Parses `script` output. Returns `nil` when Herdr is not installed or the
    /// output is unrecognizable.
    static func parse(_ output: String) -> HerdrInventory? {
        let lines = output.components(separatedBy: .newlines)
        guard !lines.contains(notInstalledMarker),
              let pathLine = lines.first(where: { $0.hasPrefix(pathMarker) }) else {
            return nil
        }

        let executable = String(pathLine.dropFirst(pathMarker.count))
        guard HerdrCommand.isSafeExecutablePath(executable) else { return nil }

        let version = lines.first(where: { $0.hasPrefix(versionMarker) })
            .map { String($0.dropFirst(versionMarker.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        var sessions: [HerdrSessionInfo] = []
        if let start = lines.firstIndex(of: listStartMarker),
           let end = lines[start...].firstIndex(of: listEndMarker) {
            sessions = parseSessionTable(Array(lines[(start + 1)..<end]))
        }

        enum Pending { case agents(String), workspaces(String) }
        var pending: Pending?
        func index(of name: String) -> Int {
            if let index = sessions.firstIndex(where: { $0.name == name }) { return index }
            sessions.append(HerdrSessionInfo(name: name, isRunning: true, agents: []))
            return sessions.count - 1
        }
        for line in lines {
            if line.hasPrefix(sessionMarker) {
                pending = .agents(String(line.dropFirst(sessionMarker.count)))
                continue
            }
            if line.hasPrefix(workspacesMarker) {
                pending = .workspaces(String(line.dropFirst(workspacesMarker.count)))
                continue
            }
            guard let current = pending, line.hasPrefix("{") else { continue }
            pending = nil
            switch current {
            case .agents(let name):
                sessions[index(of: name)].agents = parseAgentList(line) ?? []
            case .workspaces(let name):
                sessions[index(of: name)].workspaces = parseWorkspaceList(line) ?? []
            }
        }

        return HerdrInventory(executable: executable, version: version, sessions: sessions)
    }

    /// Parses `herdr session list`, a fixed-width table whose header is
    /// `name  status  directory  socket`. Column starts come from the header
    /// so paths containing spaces stay intact.
    static func parseSessionTable(_ lines: [String]) -> [HerdrSessionInfo] {
        guard let header = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let statusStart = header.range(of: "status")?.lowerBound,
              header.hasPrefix("name") else {
            return []
        }
        let statusOffset = header.distance(from: header.startIndex, to: statusStart)
        let directoryOffset = header.range(of: "directory")
            .map { header.distance(from: header.startIndex, to: $0.lowerBound) }

        return lines.drop(while: { $0 != header }).dropFirst().compactMap { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let characters = Array(line)
            let nameEnd = min(statusOffset, characters.count)
            let name = String(characters[0..<nameEnd]).trimmingCharacters(in: .whitespaces)
            let statusEnd = min(directoryOffset ?? characters.count, characters.count)
            let status = statusOffset < statusEnd
                ? String(characters[statusOffset..<statusEnd]).trimmingCharacters(in: .whitespaces)
                : ""
            guard !name.isEmpty else { return nil }
            return HerdrSessionInfo(name: name, isRunning: status == "running", agents: [])
        }
    }

    /// Parses one `herdr agent list` JSON response. Returns `nil` for an error
    /// response (for example `server_not_running`) or malformed JSON.
    static func parseAgentList(_ json: String) -> [HerdrAgent]? {
        struct Response: Decodable {
            struct Result: Decodable { let agents: [HerdrAgent] }
            let result: Result?
        }
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return response.result?.agents
    }

    /// Parses one `herdr workspace list` JSON response.
    static func parseWorkspaceList(_ json: String) -> [HerdrWorkspace]? {
        struct Response: Decodable {
            struct Result: Decodable { let workspaces: [HerdrWorkspace] }
            let result: Result?
        }
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return response.result?.workspaces
    }
}

// MARK: - Terminal commands

/// Commands Hoshi types or launches to enter Herdr. They use only single-quoted
/// tokens drawn from a conservative character set, so they behave the same
/// in bash, zsh and fish and inside Mosh's `sh -lc` wrapper.
enum HerdrCommand {
    /// Create the session if needed, then attach to its full Herdr UI.
    static func openSession(_ name: String, executable: String) -> String? {
        guard isValidSessionName(name), isSafeExecutablePath(executable) else { return nil }
        return "\(quote(executable)) --session \(quote(name))"
    }

    /// Attach straight to one agent's terminal, without Herdr's chrome.
    static func attachAgent(paneID: String, session: String, executable: String) -> String? {
        guard isValidSessionName(session),
              isValidIdentifier(paneID),
              isSafeExecutablePath(executable) else { return nil }
        return "\(quote(executable)) --session \(quote(session)) agent attach \(quote(paneID))"
    }

    /// Focus an agent in every client attached to the session. Non-interactive.
    static func focusAgent(paneID: String, session: String, executable: String) -> String? {
        guard isValidSessionName(session),
              isValidIdentifier(paneID),
              isSafeExecutablePath(executable) else { return nil }
        return "\(quote(executable)) --session \(quote(session)) agent focus \(quote(paneID))"
    }

    static func isValidSessionName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// Herdr identifiers look like `wS:p7`.
    static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func isSafeExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= 1_024
            && path.range(of: #"^[A-Za-z0-9/._+@-]+$"#, options: .regularExpression) != nil
    }

    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
