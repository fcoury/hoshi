import Foundation
import XCTest
@testable import Hoshi

@MainActor
final class HerdrIntegrationTests: XCTestCase {
    // Captured from herdr 0.9.3, trimmed to the fields Hoshi reads.
    private let discoveryOutput = """
    __HERDR_PATH__/opt/homebrew/bin/herdr
    __HERDR_VERSION__herdr 0.9.3
    __HERDR_LIST__
    name                 status   directory                                        socket
    default              running  /Users/me/.config/herdr                          /Users/me/.config/herdr/herdr.sock
    hoshi                stopped  /Users/me/My Projects                            /Users/me/.config/herdr/sessions/hoshi/herdr.sock
    __HERDR_LIST_END__
    __HERDR_SESSION__default
    {"id":"cli:agent:list","result":{"agents":[{"agent":"claude","agent_status":"blocked","completion_seq":190,"cwd":"/Users/me/code/wolfg","foreground_cwd":"/Users/me/code/wolfg/app","pane_id":"wP:p1","state_change_seq":191,"tab_id":"wP:t1","terminal_title_stripped":"App analysis","workspace_id":"wP"},{"agent":"codex","agent_status":"future_state","completion_seq":589,"cwd":"/Users/me/code/conduit","pane_id":"wS:p1","terminal_title_stripped":"  ","workspace_id":"wS"}]}}
    __HERDR_WORKSPACES__default
    {"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"workspace_id":"wS","label":"conduit","number":2,"focused":true},{"workspace_id":"wP","label":"wolfg","number":1,"focused":false}]}}

    """

    func testDiscoveryParsesSessionsAndAgents() throws {
        let inventory = try XCTUnwrap(HerdrDiscovery.parse(discoveryOutput))

        XCTAssertEqual(inventory.executable, "/opt/homebrew/bin/herdr")
        XCTAssertEqual(inventory.version, "herdr 0.9.3")
        XCTAssertEqual(inventory.sessions.map(\.name), ["default", "hoshi"])
        XCTAssertEqual(inventory.sessions.map(\.isRunning), [true, false])
        XCTAssertEqual(inventory.runningSessions.map(\.name), ["default"])

        let agents = inventory.sessions[0].agents
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents[0].paneID, "wP:p1")
        XCTAssertEqual(agents[0].status, .blocked)
        XCTAssertEqual(agents[0].cwd, "/Users/me/code/wolfg/app", "foreground_cwd wins over cwd")
        XCTAssertEqual(agents[0].directoryName, "app")
        XCTAssertEqual(agents[0].title, "App analysis")
        XCTAssertEqual(agents[0].completionSeq, 190)
        XCTAssertEqual(agents[0].displayName, "Claude")
        XCTAssertEqual(agents[1].status, .unknown, "Unknown states must not drop the agent list")
        XCTAssertNil(agents[1].title, "Blank titles are treated as missing")
        XCTAssertEqual(inventory.sessions[0].attentionCount, 1)
    }

    func testDiscoveryReportsMissingHerdr() {
        XCTAssertNil(HerdrDiscovery.parse("__HERDR_NONE__\n"))
        XCTAssertNil(HerdrDiscovery.parse(""))
        XCTAssertNil(HerdrDiscovery.parse("fish: Unknown command\n"))
    }

    func testDiscoveryRejectsUnsafeExecutablePath() {
        XCTAssertNil(HerdrDiscovery.parse("__HERDR_PATH__/tmp/her dr\n"))
        XCTAssertNil(HerdrDiscovery.parse("__HERDR_PATH__herdr\n"))
        XCTAssertNil(HerdrDiscovery.parse("__HERDR_PATH__/tmp/x;rm\n"))
    }

    func testAgentListErrorResponseIsNil() {
        let json = #"{"error":{"code":"server_not_running","message":"not running"},"id":"cli:agent:list"}"#
        XCTAssertNil(HerdrDiscovery.parseAgentList(json))
        XCTAssertNil(HerdrDiscovery.parseAgentList("not json"))
    }

    func testCommandsQuoteEveryToken() {
        XCTAssertEqual(
            HerdrCommand.openSession("hoshi", executable: "/opt/homebrew/bin/herdr"),
            "'/opt/homebrew/bin/herdr' --session 'hoshi'"
        )
        XCTAssertEqual(
            HerdrCommand.attachAgent(paneID: "wP:p1", session: "default", executable: "/usr/local/bin/herdr"),
            "'/usr/local/bin/herdr' --session 'default' agent attach 'wP:p1'"
        )
    }

    func testCommandsRejectUnsafeInput() {
        XCTAssertNil(HerdrCommand.openSession("a b", executable: "/opt/homebrew/bin/herdr"))
        XCTAssertNil(HerdrCommand.openSession("-x", executable: "/opt/homebrew/bin/herdr"))
        XCTAssertNil(HerdrCommand.openSession("x'; rm -rf ~", executable: "/opt/homebrew/bin/herdr"))
        XCTAssertNil(HerdrCommand.openSession("hoshi", executable: "herdr"))
        XCTAssertNil(HerdrCommand.attachAgent(paneID: "p1;ls", session: "default", executable: "/bin/herdr"))
    }

    func testRemoteCommandRunsScriptInPOSIXShell() {
        let command = HerdrDiscovery.remoteCommand
        XCTAssertTrue(command.hasPrefix("sh -lc '"))
        XCTAssertTrue(command.hasSuffix("' 2>/dev/null"))
        // The awk program's quotes must be escaped for the outer sh -lc.
        XCTAssertTrue(command.contains(#"awk '\''NR > 1"#))
        XCTAssertTrue(HerdrDiscovery.script.contains("/opt/homebrew/bin/herdr"))
    }

    // MARK: - Change detection

    private func inventory(_ agents: [HerdrAgent], session: String = "default") -> HerdrInventory {
        HerdrInventory(
            executable: "/opt/homebrew/bin/herdr",
            version: nil,
            sessions: [HerdrSessionInfo(name: session, isRunning: true, agents: agents)]
        )
    }

    func testCompletionSequenceIncreaseEmitsCompleted() {
        let before = inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .working, completionSeq: 3)])
        let after = inventory([HerdrAgent(
            paneID: "p1",
            agent: "claude",
            status: .done,
            cwd: "/srv/api",
            title: "Fix tests",
            completionSeq: 4
        )])

        let events = HerdrAgentChangeDetector.events(
            previous: HerdrAgentChangeDetector.snapshot(of: before),
            current: after,
            hostname: "mac.local"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .completed)
        XCTAssertEqual(events.first?.title, "Claude finished")
        XCTAssertEqual(events.first?.message, "Fix tests · in api · Herdr session default")
        XCTAssertEqual(events.first?.hostname, "mac.local")
        XCTAssertTrue(events.first?.isValid ?? false)
    }

    func testEnteringBlockedEmitsNeedsAttentionOnce() {
        let working = inventory([HerdrAgent(paneID: "p1", agent: "codex", status: .working)])
        let blocked = inventory([HerdrAgent(paneID: "p1", agent: "codex", status: .blocked)])

        let first = HerdrAgentChangeDetector.events(
            previous: HerdrAgentChangeDetector.snapshot(of: working),
            current: blocked,
            hostname: nil
        )
        XCTAssertEqual(first.map(\.kind), [.needsAttention])
        XCTAssertEqual(first.first?.title, "Codex needs input")

        let stillBlocked = HerdrAgentChangeDetector.events(
            previous: HerdrAgentChangeDetector.snapshot(of: blocked),
            current: blocked,
            hostname: nil
        )
        XCTAssertTrue(stillBlocked.isEmpty)
    }

    func testNewAgentsAndSessionsOnlyEstablishBaseline() {
        let empty = inventory([])
        let appeared = inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .blocked, completionSeq: 9)])

        XCTAssertTrue(HerdrAgentChangeDetector.events(
            previous: HerdrAgentChangeDetector.snapshot(of: empty),
            current: appeared,
            hostname: nil
        ).isEmpty)

        // The same pane ID in a different session is a different agent.
        let otherSession = inventory(
            [HerdrAgent(paneID: "p1", agent: "claude", status: .blocked, completionSeq: 10)],
            session: "hoshi"
        )
        XCTAssertTrue(HerdrAgentChangeDetector.events(
            previous: HerdrAgentChangeDetector.snapshot(of: appeared),
            current: otherSession,
            hostname: nil
        ).isEmpty)
    }

    func testMonitorBaselinesBeforeEmitting() {
        var received: [AgentEventEnvelope] = []
        var inventories: [HerdrInventory] = []
        let monitor = HerdrAgentMonitor(
            hostname: "host",
            runner: { _ in "" },
            onEvent: { received.append($0) },
            onInventory: { inventories.append($0) }
        )

        monitor.process(inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .working, completionSeq: 1)]))
        XCTAssertTrue(received.isEmpty, "The first inventory is only a baseline")

        monitor.process(inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .idle, completionSeq: 2)]))
        XCTAssertEqual(received.map(\.kind), [.completed])
        XCTAssertEqual(inventories.count, 2)
    }

    // MARK: - Phase 2

    func testDiscoveryParsesWorkspacesAndGroupsAgents() throws {
        let inventory = try XCTUnwrap(HerdrDiscovery.parse(discoveryOutput))
        let session = try XCTUnwrap(inventory.session(named: "default"))

        XCTAssertEqual(session.workspaces.map(\.label), ["conduit", "wolfg"])
        XCTAssertEqual(session.workspaces.first?.focused, true)
        XCTAssertEqual(session.agentsByWorkspace.map(\.workspace.label), ["conduit", "wolfg"])
        XCTAssertEqual(session.agentsByWorkspace.map { $0.agents.map(\.paneID) }, [["wS:p1"], ["wP:p1"]])
        XCTAssertEqual(inventory.attentionCount, 1)
    }

    func testAgentsWithUnknownWorkspaceAreGroupedLast() {
        let session = HerdrSessionInfo(
            name: "s",
            isRunning: true,
            agents: [
                HerdrAgent(paneID: "a", agent: "claude", status: .idle, workspaceID: "w1"),
                HerdrAgent(paneID: "b", agent: "codex", status: .idle, workspaceID: "gone"),
                HerdrAgent(paneID: "c", agent: "codex", status: .idle),
            ],
            workspaces: [HerdrWorkspace(id: "w1", label: "api"), HerdrWorkspace(id: "w2", label: "empty")]
        )
        XCTAssertEqual(session.agentsByWorkspace.map(\.workspace.label), ["api", "Other"])
        XCTAssertEqual(session.agentsByWorkspace.last?.agents.map(\.paneID), ["b", "c"])
    }

    func testFocusCommandQuotesTokens() {
        XCTAssertEqual(
            HerdrCommand.focusAgent(paneID: "wP:p1", session: "default", executable: "/opt/homebrew/bin/herdr"),
            "'/opt/homebrew/bin/herdr' --session 'default' agent focus 'wP:p1'"
        )
        XCTAssertNil(HerdrCommand.focusAgent(paneID: "$(id)", session: "default", executable: "/bin/herdr"))
    }

    func testAttachmentRoundTripsThroughChoicesAndPersistence() throws {
        let agent = HerdrAttachment.agent(session: "default", paneID: "wP:p1")
        XCTAssertEqual(HerdrAttachment(choice: agent.choice), agent)
        XCTAssertEqual(HerdrAttachment(choice: HerdrAttachment.session("hoshi").choice), .session("hoshi"))
        XCTAssertNil(HerdrAttachment(choice: .skip))
        XCTAssertEqual(agent.sessionName, "default")

        let descriptor = PersistedSessionDescriptor(
            id: UUID(),
            serverID: UUID(),
            serverName: "mac",
            transportPolicy: .auto,
            tmuxSession: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            lastAccessedAt: Date(timeIntervalSince1970: 2),
            herdrAttachment: agent
        )
        let decoded = try JSONDecoder().decode(
            PersistedSessionDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        XCTAssertEqual(decoded.herdrAttachment, agent)
    }

    func testDescriptorsSavedBeforeHerdrStillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","serverID":"\(UUID().uuidString)","serverName":"mac",
         "transportPolicy":"auto","tmuxSession":"main","createdAt":1,"lastAccessedAt":2}
        """
        let decoded = try JSONDecoder().decode(PersistedSessionDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tmuxSession, "main")
        XCTAssertNil(decoded.herdrAttachment)
    }

    func testMissingAgentFallsBackToItsSession() throws {
        let inventory = try XCTUnwrap(HerdrDiscovery.parse(discoveryOutput))
        XCTAssertEqual(
            ConnectionCoordinator.resolve(.agent(session: "default", paneID: "wP:p1"), in: inventory),
            .agent(session: "default", paneID: "wP:p1")
        )
        XCTAssertEqual(
            ConnectionCoordinator.resolve(.agent(session: "default", paneID: "gone:p9"), in: inventory),
            .session("default")
        )
        XCTAssertEqual(ConnectionCoordinator.resolve(.session("hoshi"), in: inventory), .session("hoshi"))
    }

    func testOnlyOneMonitorPerHostReportsEvents() {
        var first: [AgentEventEnvelope] = []
        var second: [AgentEventEnvelope] = []
        let key = "me@host:22-\(UUID().uuidString)"
        let a = HerdrAgentMonitor(hostname: "host", hostKey: key, runner: { _ in "" }, onEvent: { first.append($0) })
        let b = HerdrAgentMonitor(hostname: "host", hostKey: key, runner: { _ in "" }, onEvent: { second.append($0) })
        let before = inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .working, completionSeq: 1)])
        let after = inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .idle, completionSeq: 2)])
        let later = inventory([HerdrAgent(paneID: "p1", agent: "claude", status: .idle, completionSeq: 3)])

        a.process(before)
        b.process(before)
        a.process(after)
        b.process(after)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0, "The second monitor only tracks state")

        a.stop()
        b.process(later)
        XCTAssertEqual(second.count, 1, "The second monitor takes over without replaying")
        b.stop()
    }

    // MARK: - Replies

    func testPromptOptionsParseClaudeAndCodexMenus() {
        let claude = """
         Do you want to make this edit to Herdr.swift?
         ❯ 1. Yes
           2. Yes, allow all edits during this session (shift+tab)
           3. No, and tell Claude what to do differently (esc)
        """
        let options = HerdrPromptOption.parse(claude)
        XCTAssertEqual(options.map(\.number), [1, 2, 3])
        XCTAssertEqual(options.first?.label, "Yes")
        XCTAssertEqual(options.map(\.isSelected), [true, false, false])

        let codex = """
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command (p)
          3. No, and tell Codex what to do differently (esc)
          Press enter to confirm or esc to cancel
        """
        XCTAssertEqual(HerdrPromptOption.parse(codex).map(\.label).last, "No, and tell Codex what to do differently (esc)")
    }

    func testPromptOptionsIgnoreProseAndBrokenSequences() {
        XCTAssertTrue(HerdrPromptOption.parse("Step 1. install\nthen run it").isEmpty)
        XCTAssertTrue(HerdrPromptOption.parse("1. only one option").isEmpty)
        XCTAssertTrue(HerdrPromptOption.parse("1. first\n3. skipped").isEmpty)
        // A later menu replaces an earlier numbered list.
        let output = "1. old\n2. list\nsome text\n❯ 1. Allow\n  2. Deny"
        XCTAssertEqual(HerdrPromptOption.parse(output).map(\.label), ["Allow", "Deny"])
    }

    func testKeysAreLimitedToASafeSet() {
        XCTAssertEqual(HerdrKey.key(for: "2"), .character("2"))
        XCTAssertEqual(HerdrKey.key(for: "y"), .character("y"))
        XCTAssertNil(HerdrKey.key(for: ";"))
        XCTAssertNil(HerdrKey.key(for: "é"))
        XCTAssertEqual(
            HerdrCommand.sendKeys([.character("2"), .enter, .escape], paneID: "wP:p1", session: "default", executable: "/x/herdr"),
            "'/x/herdr' --session 'default' agent send-keys 'wP:p1' '2' 'enter' 'esc'"
        )
        XCTAssertNil(HerdrCommand.sendKeys([], paneID: "wP:p1", session: "default", executable: "/x/herdr"))
    }

    func testSubmittedTextIsBase64AndRoutedByAgentState() throws {
        let text = "it's \"fine\" $HOME `id`\nnext"
        let prompt = try XCTUnwrap(HerdrCommand.submitText(
            text, toBlockedAgent: false, paneID: "wP:p1", session: "default", executable: "/x/herdr"
        ))
        XCTAssertTrue(prompt.contains("agent prompt"))
        XCTAssertTrue(prompt.contains(Data(text.utf8).base64EncodedString()))
        XCTAssertFalse(prompt.contains("$HOME `id`"), "Raw text never appears in the command")

        let blocked = try XCTUnwrap(HerdrCommand.submitText(
            text, toBlockedAgent: true, paneID: "wP:p1", session: "default", executable: "/x/herdr"
        ))
        XCTAssertTrue(blocked.contains("pane run"))
        XCTAssertTrue(blocked.contains(Data("it's \"fine\" $HOME `id` next".utf8).base64EncodedString()),
                      "Blocked replies stay on one line")

        XCTAssertNil(HerdrCommand.submitText("\n", toBlockedAgent: false, paneID: "p", session: "s", executable: "/x/herdr"))
        XCTAssertNil(HerdrCommand.submitText(String(repeating: "a", count: 9_000), toBlockedAgent: false, paneID: "p", session: "s", executable: "/x/herdr"))
    }

    func testCapturedResultsReportExitStatusAndHerdrErrors() {
        let ok = HerdrCommand.parseResult("line one\nline two\n\n__HERDR_EXIT__0\n")
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.output, "line one\nline two")

        let failed = HerdrCommand.parseResult(
            #"{"error":{"code":"agent_blocked","message":"agent is blocked"},"id":"x"}"# + "\n\n__HERDR_EXIT__1\n"
        )
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.errorMessage, "agent is blocked")

        XCTAssertFalse(HerdrCommand.parseResult("no marker").succeeded)
        XCTAssertTrue(HerdrCommand.captured("'/x/herdr' agent list").hasPrefix("sh -c '"))
    }

    func testEventsCarryAValidatedHerdrTarget() {
        let before = inventory([HerdrAgent(paneID: "wP:p1", agent: "claude", status: .working)])
        let after = inventory([HerdrAgent(paneID: "wP:p1", agent: "claude", status: .blocked)])
        let event = HerdrAgentChangeDetector.events(
            previous: HerdrAgentChangeDetector.snapshot(of: before),
            current: after,
            hostname: nil
        ).first
        XCTAssertEqual(event?.herdrTarget, HerdrAgentTarget(session: "default", paneID: "wP:p1"))

        let invalid = AgentEventEnvelope(
            kind: .needsAttention,
            title: "x",
            herdrTarget: HerdrAgentTarget(session: "bad name", paneID: "p1")
        )
        XCTAssertFalse(invalid.isValid)
    }

    // MARK: - Live Activity content

    func testLiveActivityStateDecodesPayloadsFromOlderBuilds() throws {
        let json = """
        {"status":"running","displayName":"mac","attentionCount":0,"updatedAt":0,"detailsAreHidden":false}
        """
        let state = try JSONDecoder().decode(AgentLiveActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.headline)
        XCTAssertEqual(state.workingCount, 0)
        XCTAssertFalse(state.hasAgentCounts)
        XCTAssertEqual(state.primaryText, "Connected")
    }

    func testLiveActivityTextRespectsPrivacyAndCounts() {
        var state = AgentLiveActivityAttributes.ContentState(
            status: .running,
            displayName: "m5pro",
            tmuxSession: "Herdr default",
            attentionCount: 0,
            latestEventID: nil,
            updatedAt: Date(),
            detailsAreHidden: false,
            headline: nil,
            workingCount: 2
        )
        XCTAssertEqual(state.primaryText, "2 agents working")
        XCTAssertEqual(state.secondaryText, "m5pro · Herdr default")
        XCTAssertEqual(state.actionTitle, "Open")

        state.blockedCount = 1
        XCTAssertEqual(state.displayStatus, .needsAttention, "A waiting agent outranks running")
        XCTAssertEqual(state.primaryText, "Agent needs input")
        XCTAssertEqual(state.actionTitle, "Reply")

        state.headline = "Claude needs input"
        XCTAssertEqual(state.primaryText, "Claude needs input")

        state.detailsAreHidden = true
        XCTAssertEqual(state.primaryText, "Agent needs input", "Headlines stay hidden when details are private")
        XCTAssertNil(state.secondaryText)
    }
}
