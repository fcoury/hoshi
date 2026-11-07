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
    /// The full Herdr UI of a machine saved in this host's Herdr
    /// (`herdr --remote`), optionally focused on one agent first.
    case machine(id: String, paneID: String?)

    /// The local session name, or the machine ID for a saved machine.
    var sessionName: String {
        switch self {
        case .session(let name): name
        case .agent(let session, _): session
        case .machine(let id, _): id
        }
    }

    var machineID: String? {
        if case .machine(let id, _) = self { return id }
        return nil
    }

    var choice: TmuxChoice {
        switch self {
        case .session(let name): .herdrSession(name)
        case .agent(let session, let paneID): .herdrAgent(session: session, paneID: paneID)
        case .machine(let id, let paneID): .herdrMachine(id: id, paneID: paneID)
        }
    }

    init?(choice: TmuxChoice) {
        switch choice {
        case .herdrSession(let name): self = .session(name)
        case .herdrAgent(let session, let paneID): self = .agent(session: session, paneID: paneID)
        case .herdrMachine(let id, let paneID): self = .machine(id: id, paneID: paneID)
        default: return nil
        }
    }

    /// Whether this terminal shows the agent at `target`: its whole Herdr
    /// session or machine, or that one agent pane. Only these agents raise
    /// alerts for the terminal.
    func shows(_ target: HerdrAgentTarget) -> Bool {
        switch self {
        case .session(let name):
            target.machineID == nil && target.session == name
        case .agent(let session, let paneID):
            target.machineID == nil && target.session == session && target.paneID == paneID
        case .machine(let id, _):
            target.machineID == id
        }
    }

    /// A stable key for this view, so two terminals on the same Herdr view
    /// report each event once.
    var reporterKey: String {
        switch self {
        case .session(let name): "session/\(name)"
        case .agent(let session, let paneID): "agent/\(session)/\(paneID)"
        case .machine(let id, _): "machine/\(id)"
        }
    }

    /// Whether this terminal shows the Herdr UI that owns `session`, so
    /// focusing an agent there switches the view in place.
    func shows(_ session: HerdrSessionInfo) -> Bool {
        switch self {
        case .session(let name): session.machine == nil && session.name == name
        case .machine(let id, _): session.machine?.id == id
        case .agent: false
        }
    }
}

/// A named, persistent Herdr session (Herdr's own default session is `default`).
struct HerdrSessionInfo: Identifiable, Equatable, Sendable {
    let name: String
    let isRunning: Bool
    var agents: [HerdrAgent]
    var workspaces: [HerdrWorkspace]
    /// Set for the session of a machine saved in this host's Herdr.
    var machine: HerdrMachine?

    init(
        name: String,
        isRunning: Bool,
        agents: [HerdrAgent],
        workspaces: [HerdrWorkspace] = [],
        machine: HerdrMachine? = nil
    ) {
        self.name = name
        self.isRunning = isRunning
        self.agents = agents
        self.workspaces = workspaces
        self.machine = machine
    }

    var id: String { machine.map { "machine:\($0.id)" } ?? name }

    /// "default" on this host, or the machine's label.
    var displayName: String { machine?.label ?? name }

    func target(for agent: HerdrAgent) -> HerdrAgentTarget {
        HerdrAgentTarget(session: name, paneID: agent.paneID, machineID: machine?.id)
    }

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

/// An SSH machine saved in the connected host's Herdr (`herdr machine add`).
/// Hoshi reaches its agents through the host with `herdr --machine`, so the
/// phone never needs its own route or credentials for that machine.
struct HerdrMachine: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// The host's SSH target for the machine, such as `user@build-box`.
    let target: String
    /// The remote Herdr session the profile uses.
    let session: String?
    let enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id, label, target, session, enabled
    }

    init(id: String, label: String, target: String, session: String? = nil, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.target = target
        self.session = session
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        self.label = (label?.isEmpty == false ? label : nil) ?? (target.isEmpty ? id : target)
        session = try container.decodeIfPresent(String.self, forKey: .session)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// What Hoshi discovered about Herdr on the connected host.
struct HerdrInventory: Equatable, Sendable {
    /// Absolute path of the resolved `herdr` executable on the remote host.
    let executable: String
    let version: String?
    /// Local sessions first, then one session per saved machine.
    var sessions: [HerdrSessionInfo]

    var runningSessions: [HerdrSessionInfo] { sessions.filter(\.isRunning) }

    /// The running agents a terminal attached to `attachment` shows; none
    /// for a terminal that is not in Herdr.
    func agents(shownBy attachment: HerdrAttachment?) -> [HerdrAgent] {
        guard let attachment else { return [] }
        return runningSessions.flatMap { session in
            session.agents.filter { attachment.shows(session.target(for: $0)) }
        }
    }
    var localSessions: [HerdrSessionInfo] { sessions.filter { $0.machine == nil } }
    var machineSessions: [HerdrSessionInfo] { sessions.filter { $0.machine != nil } }

    var attentionCount: Int { sessions.reduce(0) { $0 + $1.attentionCount } }

    /// A session on this host by name.
    func session(named name: String) -> HerdrSessionInfo? {
        sessions.first { $0.machine == nil && $0.name == name }
    }

    func session(for target: HerdrAgentTarget) -> HerdrSessionInfo? {
        if let machineID = target.machineID {
            return sessions.first { $0.machine?.id == machineID }
        }
        return session(named: target.session)
    }

    func machine(id: String) -> HerdrMachine? {
        sessions.lazy.compactMap(\.machine).first { $0.id == id }
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
    private static let machinesStartMarker = "__HERDR_MACHINES__"
    private static let machinesEndMarker = "__HERDR_MACHINES_END__"
    private static let machineAgentsMarker = "__HERDR_MACHINE__"
    private static let machineWorkspacesMarker = "__HERDR_MACHINE_WS__"
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
        echo \(machinesStartMarker); "$H" machine list --json 2>/dev/null; echo; echo \(machinesEndMarker); \
        "$H" machine list --json 2>/dev/null | awk -F'"' '$2 == "id" { print $4 }' | \
        while read -r m; do echo "\(machineAgentsMarker)$m"; "$H" --machine "$m" agent list 2>/dev/null; echo; \
        echo "\(machineWorkspacesMarker)$m"; "$H" --machine "$m" workspace list 2>/dev/null; echo; done; \
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

        var machines: [HerdrMachine] = []
        if let start = lines.firstIndex(of: machinesStartMarker),
           let end = lines[start...].firstIndex(of: machinesEndMarker) {
            machines = parseMachineList(lines[(start + 1)..<end].joined(separator: "\n")) ?? []
        }
        var machineAgents: [String: [HerdrAgent]] = [:]
        var machineWorkspaces: [String: [HerdrWorkspace]] = [:]

        enum Pending {
            case agents(String), workspaces(String), machineAgents(String), machineWorkspaces(String)
        }
        var pending: Pending?
        func index(of name: String) -> Int {
            if let index = sessions.firstIndex(where: { $0.name == name }) { return index }
            sessions.append(HerdrSessionInfo(name: name, isRunning: true, agents: []))
            return sessions.count - 1
        }
        let markers: [(String, (String) -> Pending)] = [
            (machineWorkspacesMarker, Pending.machineWorkspaces),
            (machineAgentsMarker, Pending.machineAgents),
            (workspacesMarker, Pending.workspaces),
            (sessionMarker, Pending.agents),
        ]
        for line in lines {
            if let (marker, make) = markers.first(where: { line.hasPrefix($0.0) }) {
                pending = make(String(line.dropFirst(marker.count)))
                continue
            }
            guard let current = pending, line.hasPrefix("{") else { continue }
            pending = nil
            switch current {
            case .agents(let name):
                sessions[index(of: name)].agents = parseAgentList(line) ?? []
            case .workspaces(let name):
                sessions[index(of: name)].workspaces = parseWorkspaceList(line) ?? []
            case .machineAgents(let id):
                machineAgents[id] = parseAgentList(line)
            case .machineWorkspaces(let id):
                machineWorkspaces[id] = parseWorkspaceList(line)
            }
        }

        // A machine is running when Herdr could list its agents through the host.
        for machine in machines where machine.enabled && HerdrCommand.isValidIdentifier(machine.id) {
            sessions.append(HerdrSessionInfo(
                name: machine.session ?? "default",
                isRunning: machineAgents[machine.id] != nil,
                agents: machineAgents[machine.id] ?? [],
                workspaces: machineWorkspaces[machine.id] ?? [],
                machine: machine
            ))
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

    /// Parses `herdr machine list --json`.
    static func parseMachineList(_ json: String) -> [HerdrMachine]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([HerdrMachine].self, from: data)
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

/// Keys Hoshi may press in an agent. A closed set keeps replies predictable.
enum HerdrKey: Equatable, Sendable {
    case enter
    case escape
    case up
    case down
    case tab
    case interrupt
    case character(Character)

    var token: String {
        switch self {
        case .enter: "enter"
        case .escape: "esc"
        case .up: "up"
        case .down: "down"
        case .tab: "tab"
        case .interrupt: "ctrl+c"
        case .character(let character): String(character)
        }
    }

    /// Only digits and ASCII letters are allowed as single characters.
    static func key(for value: Character) -> HerdrKey? {
        guard value.isASCII, value.isLetter || value.isNumber else { return nil }
        return HerdrKey.character(value)
    }
}

/// A numbered choice detected in an agent's approval or question prompt.
struct HerdrPromptOption: Identifiable, Equatable, Sendable {
    let number: Int
    let label: String
    let isSelected: Bool

    var id: Int { number }

    /// Finds the numbered menu at the bottom of an agent's output, as drawn
    /// by Claude Code (`❯ 1. Yes`) and Codex (`› 1. Yes, proceed (y)`).
    static func parse(_ output: String) -> [HerdrPromptOption] {
        let lines = output.components(separatedBy: .newlines).suffix(30)
        var options: [HerdrPromptOption] = []
        let pattern = #"^[\s│|]*([❯›>▶→])?\s*([1-9])[.)]\s+(.+?)[\s│|]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 2), in: line),
                  let labelRange = Range(match.range(at: 3), in: line),
                  let number = Int(line[numberRange]) else {
                continue
            }
            if number == 1 { options.removeAll() }
            guard number == options.count + 1 else { continue }
            options.append(HerdrPromptOption(
                number: number,
                label: String(line[labelRange]).trimmingCharacters(in: .whitespaces),
                isSelected: match.range(at: 1).location != NSNotFound
            ))
        }
        return options.count >= 2 ? options : []
    }
}

/// Identifies one agent for replies and deep links.
struct HerdrAgentTarget: Codable, Hashable, Identifiable, Sendable {
    let session: String
    let paneID: String
    /// Set for an agent on a machine saved in the host's Herdr.
    var machineID: String? = nil

    var id: String { "\(machineID ?? "local")/\(session)/\(paneID)" }

    var isValid: Bool {
        HerdrCommand.isValidSessionName(session)
            && HerdrCommand.isValidIdentifier(paneID)
            && (machineID.map(HerdrCommand.isValidIdentifier) ?? true)
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

    /// Opens a saved machine's full Herdr UI through the host. Herdr runs the
    /// SSH connection itself, so it uses the host's keys and SSH config.
    static func openMachine(_ machine: HerdrMachine, executable: String) -> String? {
        guard isValidSSHTarget(machine.target), isSafeExecutablePath(executable) else { return nil }
        var command = "\(quote(executable)) --remote \(quote(machine.target))"
        if let session = machine.session {
            guard isValidSessionName(session) else { return nil }
            command += " --session \(quote(session))"
        }
        return command
    }

    /// The global flag pair that selects a local session or a saved machine.
    /// Herdr does not allow combining `--machine` with `--session`.
    private static func scope(session: String, machineID: String?) -> (flag: String, value: String)? {
        if let machineID {
            return isValidIdentifier(machineID) ? ("--machine", machineID) : nil
        }
        return isValidSessionName(session) ? ("--session", session) : nil
    }

    private static func agentCommand(
        _ subcommand: String,
        paneID: String,
        session: String,
        machineID: String?,
        executable: String
    ) -> String? {
        guard let scope = scope(session: session, machineID: machineID),
              isValidIdentifier(paneID),
              isSafeExecutablePath(executable) else { return nil }
        return "\(quote(executable)) \(scope.flag) \(quote(scope.value)) agent \(subcommand) \(quote(paneID))"
    }

    /// Focus an agent in every client attached to the session. Non-interactive.
    static func focusAgent(paneID: String, session: String, machineID: String? = nil, executable: String) -> String? {
        agentCommand("focus", paneID: paneID, session: session, machineID: machineID, executable: executable)
    }

    /// Recent output of an agent, without ANSI styling.
    static func readAgent(
        paneID: String,
        session: String,
        machineID: String? = nil,
        executable: String,
        lines: Int = 60
    ) -> String? {
        let count = min(max(lines, 1), 400)
        return agentCommand("read", paneID: paneID, session: session, machineID: machineID, executable: executable)
            .map { $0 + " --source recent-unwrapped --lines \(count)" }
    }

    /// Presses keys in an agent, for example to answer an approval prompt.
    static func sendKeys(
        _ keys: [HerdrKey],
        paneID: String,
        session: String,
        machineID: String? = nil,
        executable: String
    ) -> String? {
        guard !keys.isEmpty else { return nil }
        let tokens = keys.map { quote($0.token) }.joined(separator: " ")
        return agentCommand("send-keys", paneID: paneID, session: session, machineID: machineID, executable: executable)
            .map { $0 + " " + tokens }
    }

    /// Submits free text. A ready agent gets `agent prompt`; a blocked one is
    /// answered with `pane run`, because Herdr refuses prompts while an
    /// approval or question is showing.
    ///
    /// The text travels base64-encoded and is decoded by `sh`, so the user's
    /// login shell (bash, zsh or fish) never interprets it.
    static func submitText(
        _ text: String,
        toBlockedAgent isBlocked: Bool,
        paneID: String,
        session: String,
        machineID: String? = nil,
        executable: String
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 8_192,
              let scope = scope(session: session, machineID: machineID),
              isValidIdentifier(paneID),
              isSafeExecutablePath(executable) else { return nil }
        // A newline would submit a blocked prompt early, so keep replies on one line.
        let body = isBlocked
            ? trimmed.components(separatedBy: .newlines).joined(separator: " ")
            : trimmed
        let payload = Data(body.utf8).base64EncodedString()
        let action = isBlocked ? "pane run" : "agent prompt"
        let script = #"T=$(printf %s "$5" | base64 -d) && exec "$1" "$2" "$3" "# + action + #" "$4" "$T""#
        return "sh -c \(quote(script)) herdr \(quote(executable)) \(quote(scope.flag)) \(quote(scope.value)) "
            + "\(quote(paneID)) \(quote(payload))"
    }

    private static let exitMarker = "__HERDR_EXIT__"

    /// Runs `command` in `sh` so its exit status and Herdr's error message
    /// survive even when the SSH channel treats a non-zero exit as failure.
    static func captured(_ command: String) -> String {
        // The extra `echo` keeps the marker on its own line when the output
        // does not end with a newline.
        "sh -c \(quote(command + " 2>&1; s=$?; echo; echo \(exitMarker)$s"))"
    }

    struct Result: Equatable, Sendable {
        let output: String
        let succeeded: Bool
        /// Herdr's own error message, when it printed one.
        let errorMessage: String?
    }

    static func parseResult(_ raw: String) -> Result {
        var lines = raw.components(separatedBy: "\n")
        var status: Int?
        if let index = lines.lastIndex(where: { $0.hasPrefix(exitMarker) }) {
            status = Int(lines[index].dropFirst(exitMarker.count).trimmingCharacters(in: .whitespaces))
            lines.removeSubrange(index...)
            if lines.last == "" { lines.removeLast() }
        }
        let output = lines.joined(separator: "\n")

        struct ErrorResponse: Decodable {
            struct Body: Decodable { let code: String?; let message: String? }
            let error: Body
        }
        let errorMessage = output.components(separatedBy: .newlines)
            .lazy
            .compactMap { line -> String? in
                guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                      let response = try? JSONDecoder().decode(ErrorResponse.self, from: data) else { return nil }
                return response.error.message ?? response.error.code
            }
            .first
        return Result(
            output: output,
            succeeded: status == 0 && errorMessage == nil,
            errorMessage: errorMessage
        )
    }

    static func isValidSessionName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// Herdr identifiers look like `wS:p7`.
    static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil
    }

    /// An SSH alias or `user@host`, as saved by `herdr machine add`.
    static func isValidSSHTarget(_ target: String) -> Bool {
        target.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._@:\[\]-]{0,254}$"#, options: .regularExpression) != nil
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
