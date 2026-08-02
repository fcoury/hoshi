import LocalAuthentication
import SwiftData
import SwiftUI
import XCTest
@testable import Hoshi

@MainActor
final class DailyWorkflowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "hoshi.daily-workflow.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTerminalKeySequencePreservesUTF8Text() throws {
        XCTAssertEqual(try TerminalKeySequence.parse("Olá 🌟"), Array("Olá 🌟".utf8))
    }

    func testTerminalKeySequenceEncodesUpperAndLowerCaseControlCharacters() throws {
        XCTAssertEqual(try TerminalKeySequence.parse("^B"), [0x02])
        XCTAssertEqual(try TerminalKeySequence.parse("^b"), [0x02])
        XCTAssertEqual(try TerminalKeySequence.parse("^@"), [0x00])
        XCTAssertEqual(try TerminalKeySequence.parse("^?"), [0x7F])
    }

    func testTerminalKeySequenceEncodesNamedEscapes() throws {
        XCTAssertEqual(
            try TerminalKeySequence.parse("\\e[1;5A\\n\\r\\t\\0"),
            [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41, 0x0A, 0x0D, 0x09, 0x00]
        )
    }

    func testTerminalKeySequenceEncodesHexadecimalBytes() throws {
        XCTAssertEqual(try TerminalKeySequence.parse("\\x1b\\x00\\xFF"), [0x1B, 0x00, 0xFF])
    }

    func testTerminalKeySequenceSupportsLiteralBackslashAndCaret() throws {
        XCTAssertEqual(try TerminalKeySequence.parse("\\\\\\^"), [0x5C, 0x5E])
    }

    func testTerminalKeySequenceRejectsEmptyInput() {
        XCTAssertThrowsError(try TerminalKeySequence.parse("")) { error in
            XCTAssertEqual(error as? TerminalKeySequenceError, .empty)
        }
    }

    func testTerminalKeySequenceRejectsIncompleteHexadecimalEscape() {
        XCTAssertThrowsError(try TerminalKeySequence.parse("\\xA")) { error in
            XCTAssertEqual(error as? TerminalKeySequenceError, .incompleteEscape)
        }
    }

    func testTerminalKeySequenceRejectsInvalidHexadecimalEscape() {
        XCTAssertThrowsError(try TerminalKeySequence.parse("\\xG0")) { error in
            XCTAssertEqual(error as? TerminalKeySequenceError, .invalidEscape("\\xG0"))
        }
    }

    func testTerminalKeySequenceRejectsUnsupportedEscapes() {
        XCTAssertThrowsError(try TerminalKeySequence.parse("\\q"))
        XCTAssertThrowsError(try TerminalKeySequence.parse("^1"))
        XCTAssertThrowsError(try TerminalKeySequence.parse("^"))
    }

    func testTmuxCommandsPrependConfiguredPrefix() throws {
        let command = TmuxCommand(title: "Split", sequence: "%")

        XCTAssertEqual(try command.bytes(prefix: "^B"), [0x02, 0x25])
        XCTAssertEqual(try command.bytes(prefix: "^A"), [0x01, 0x25])
    }

    func testCustomShortcutCanSendRawBytesWithoutTmuxPrefix() throws {
        let command = TmuxCommand(title: "Arrow", sequence: "\\e[A", sendsPrefix: false)

        XCTAssertEqual(try command.bytes(prefix: "^B"), [0x1B, 0x5B, 0x41])
    }

    func testBuiltInTmuxCommandsHaveUniqueIdentifiersAndValidSequences() throws {
        let identifiers = TmuxCommand.builtIn.map(\.id)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.contains("split-vertical"))
        XCTAssertTrue(identifiers.contains("session-list"))

        for command in TmuxCommand.builtIn {
            XCTAssertFalse(try command.bytes(prefix: "^B").isEmpty, command.title)
        }
    }

    func testTmuxConfigurationDefaultsToControlB() {
        let configuration = TmuxConfigurationService(defaults: defaults)

        XCTAssertEqual(configuration.prefix, "^B")
        XCTAssertTrue(configuration.customCommands.isEmpty)
    }

    func testTmuxPrefixPersistsBetweenConfigurationInstances() throws {
        let configuration = TmuxConfigurationService(defaults: defaults)
        try configuration.setPrefix("^A")

        let reloaded = TmuxConfigurationService(defaults: defaults)
        XCTAssertEqual(reloaded.prefix, "^A")
    }

    func testInvalidTmuxPrefixDoesNotReplaceCurrentPrefix() {
        let configuration = TmuxConfigurationService(defaults: defaults)

        XCTAssertThrowsError(try configuration.setPrefix("\\xG0"))
        XCTAssertEqual(configuration.prefix, "^B")
    }

    func testInvalidPersistedTmuxPrefixFallsBackToControlB() {
        defaults.set("\\x", forKey: "com.hoshi.tmux.prefix")

        XCTAssertEqual(TmuxConfigurationService(defaults: defaults).prefix, "^B")
    }

    func testCustomTmuxCommandPersistsAndCanBeUpdated() throws {
        let configuration = TmuxConfigurationService(defaults: defaults)
        var command = TmuxCommand(title: "Agents", sequence: "s")
        try configuration.saveCustomCommand(command)

        let reloaded = TmuxConfigurationService(defaults: defaults)
        XCTAssertEqual(reloaded.customCommands, [command])

        command.title = "Agent Sessions"
        try reloaded.saveCustomCommand(command)

        XCTAssertEqual(reloaded.customCommands.count, 1)
        XCTAssertEqual(reloaded.customCommands.first?.title, "Agent Sessions")
    }

    func testCustomTmuxCommandRejectsMissingTitleAndInvalidSequence() {
        let configuration = TmuxConfigurationService(defaults: defaults)

        XCTAssertThrowsError(try configuration.saveCustomCommand(TmuxCommand(title: " ", sequence: "x")))
        XCTAssertThrowsError(try configuration.saveCustomCommand(TmuxCommand(title: "Broken", sequence: "\\x")))
        XCTAssertTrue(configuration.customCommands.isEmpty)
    }

    func testCustomTmuxCommandCanBeRemoved() throws {
        let configuration = TmuxConfigurationService(defaults: defaults)
        let command = TmuxCommand(title: "Detach", sequence: "d")
        try configuration.saveCustomCommand(command)

        configuration.removeCustomCommand(id: command.id)

        XCTAssertTrue(configuration.customCommands.isEmpty)
        XCTAssertTrue(TmuxConfigurationService(defaults: defaults).customCommands.isEmpty)
    }

    func testFavoritesAreSeparatedFromRecentAndRemainingServers() {
        let favorite = makeServer(name: "Favorite", favorite: true, connectedAt: 100)
        let recent = makeServer(name: "Recent", connectedAt: 200)
        let remaining = makeServer(name: "Remaining")

        let catalog = ServerCatalog(servers: [remaining, recent, favorite])

        XCTAssertEqual(catalog.favorites.map(\.name), ["Favorite"])
        XCTAssertEqual(catalog.recent.map(\.name), ["Recent"])
        XCTAssertEqual(catalog.remaining.map(\.name), ["Remaining"])
    }

    func testRecentServersAreSortedByLastConnectionAndLimited() {
        let servers = (0..<7).map { makeServer(name: "Server \($0)", connectedAt: TimeInterval($0)) }

        let catalog = ServerCatalog(servers: servers, recentLimit: 3)

        XCTAssertEqual(catalog.recent.map(\.name), ["Server 6", "Server 5", "Server 4"])
        XCTAssertEqual(catalog.remaining.count, 4)
    }

    func testFavoriteServersAreSortedByRecency() {
        let older = makeServer(name: "Older", favorite: true, connectedAt: 10)
        let newer = makeServer(name: "Newer", favorite: true, connectedAt: 20)

        XCTAssertEqual(ServerCatalog(servers: [older, newer]).favorites.map(\.name), ["Newer", "Older"])
    }

    func testOrderedCatalogKeepsFavoritesFirstThenRecentAndRemaining() {
        let olderFavorite = makeServer(name: "Older Favorite", favorite: true, connectedAt: 10)
        let newerFavorite = makeServer(name: "Newer Favorite", favorite: true, connectedAt: 20)
        let olderRecent = makeServer(name: "Older Recent", connectedAt: 30)
        let newerRecent = makeServer(name: "Newer Recent", connectedAt: 40)
        let remaining = makeServer(name: "Alphabetical")

        let catalog = ServerCatalog(
            servers: [remaining, olderRecent, newerFavorite, newerRecent, olderFavorite],
            recentLimit: 2
        )

        XCTAssertEqual(
            catalog.ordered.map(\.name),
            ["Newer Favorite", "Older Favorite", "Newer Recent", "Older Recent", "Alphabetical"]
        )
    }

    func testServerCatalogSearchMatchesNamesHostsUsersAndTmuxSessions() {
        let server = Server(
            name: "Production",
            hostname: "infra.example.com",
            username: "deploy",
            tmuxSession: "coding-agents"
        )

        for query in ["prod", "infra", "DEPLOY", "agents"] {
            XCTAssertFalse(ServerCatalog(servers: [server], searchText: query).isEmpty, query)
        }
        XCTAssertTrue(ServerCatalog(servers: [server], searchText: "missing").isEmpty)
    }

    func testServerCatalogSearchTrimsWhitespace() {
        let server = makeServer(name: "Production")

        XCTAssertEqual(ServerCatalog(servers: [server], searchText: "  prod  ").remaining.count, 1)
    }

    func testDuplicateServerNamesRemainUnique() {
        XCTAssertEqual(ServerCatalog.duplicatedName(from: "Work", existingNames: []), "Work Copy")
        XCTAssertEqual(
            ServerCatalog.duplicatedName(
                from: "Work",
                existingNames: ["Work", "Work Copy", "Work Copy 2"]
            ),
            "Work Copy 3"
        )
    }

    func testFavoriteFlagPersistsInSwiftData() throws {
        let container = try ModelContainer(
            for: Server.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let server = makeServer(name: "Pinned", favorite: true)
        context.insert(server)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Server>()).first?.isFavorite, true)
    }

    func testPreparingDuplicateDoesNotInsertAProfile() throws {
        let container = try ModelContainer(
            for: Server.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let server = makeServer(name: "Original")
        context.insert(server)
        try context.save()

        let hostingController = UIHostingController(rootView:
            AddServerView(duplicatedServer: server, suggestedName: "Original Copy")
                .modelContainer(container)
        )
        hostingController.loadViewIfNeeded()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Server>()).count, 1)
    }

    func testTmuxSessionParserCapturesCreationAndActivity() {
        let sessions = TmuxDetectionService.parseSessionList("agents|3|1|1700000000|1600000000")
        let session = sessions.first

        XCTAssertEqual(session?.name, "agents")
        XCTAssertEqual(session?.windows, 3)
        XCTAssertEqual(session?.isAttached, true)
        XCTAssertEqual(session?.lastActivity, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(session?.createdAt, Date(timeIntervalSince1970: 1_600_000_000))
    }

    func testTmuxSessionParserSortsMostRecentlyActiveFirst() {
        let sessions = TmuxDetectionService.parseSessionList("older|1|0|100|50\nnewer|2|1|300|200")

        XCTAssertEqual(sessions.map(\.name), ["newer", "older"])
    }

    func testTmuxSessionParserIgnoresMalformedRows() {
        let sessions = TmuxDetectionService.parseSessionList("bad|x|1|10|5\n|2|0|10|5\ngood|1|0|30|20")

        XCTAssertEqual(sessions.map(\.name), ["good"])
        XCTAssertTrue(TmuxDetectionService.parseSessionList("__NO_SESSIONS__").isEmpty)
    }

    func testNamedTmuxSessionsAreSafelyShellEscaped() {
        XCTAssertEqual(
            TmuxDetectionService.newSessionCommand(sessionName: "agent's shell"),
            "tmux new-session -s 'agent'\\''s shell'"
        )
        XCTAssertEqual(TmuxDetectionService.newSessionCommand(), "tmux new-session")
    }

    func testTmuxSessionNamesRejectReservedAndControlCharacters() {
        XCTAssertTrue(TmuxDetectionService.isValidSessionName("coding agents"))
        XCTAssertFalse(TmuxDetectionService.isValidSessionName(""))
        XCTAssertFalse(TmuxDetectionService.isValidSessionName("   "))
        XCTAssertFalse(TmuxDetectionService.isValidSessionName("agent:one"))
        XCTAssertFalse(TmuxDetectionService.isValidSessionName("agent.one"))
        XCTAssertFalse(TmuxDetectionService.isValidSessionName("agent\nname"))
    }

    func testAppLockStartsDisabledAndUnlocked() {
        let lock = AppLockService(defaults: defaults, authenticator: MockAppLockAuthenticator())

        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testAppLockEnablesOnlyAfterSuccessfulAuthentication() async {
        let authenticator = MockAppLockAuthenticator()
        let lock = AppLockService(defaults: defaults, authenticator: authenticator)

        await lock.setEnabled(true)

        XCTAssertTrue(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(authenticator.authenticationCount, 1)
    }

    func testAppLockRefusesToEnableWhenDeviceCannotAuthenticate() async {
        let authenticator = MockAppLockAuthenticator()
        authenticator.available = false
        let lock = AppLockService(defaults: defaults, authenticator: authenticator)

        await lock.setEnabled(true)

        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
        XCTAssertNotNil(lock.errorMessage)
        XCTAssertEqual(authenticator.authenticationCount, 0)
    }

    func testAppLockFailedEnableDoesNotPersistAnEnabledState() async {
        let authenticator = MockAppLockAuthenticator()
        authenticator.shouldThrow = true
        let lock = AppLockService(defaults: defaults, authenticator: authenticator)

        await lock.setEnabled(true)

        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "com.hoshi.security.appLockEnabled"))
        XCTAssertNotNil(lock.errorMessage)
    }

    func testEnabledAppLockLocksAndUnlocks() async {
        let authenticator = MockAppLockAuthenticator()
        let lock = AppLockService(defaults: defaults, authenticator: authenticator)
        await lock.setEnabled(true)

        lock.lock()
        XCTAssertTrue(lock.isLocked)

        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(authenticator.authenticationCount, 2)
    }

    func testFailedUnlockKeepsSessionProtected() async {
        let authenticator = MockAppLockAuthenticator()
        let lock = AppLockService(defaults: defaults, authenticator: authenticator)
        await lock.setEnabled(true)
        lock.lock()
        authenticator.shouldThrow = true

        await lock.unlock()

        XCTAssertTrue(lock.isLocked)
        XCTAssertNotNil(lock.errorMessage)
    }

    func testDisablingAppLockUnlocksImmediately() async {
        let lock = AppLockService(defaults: defaults, authenticator: MockAppLockAuthenticator())
        await lock.setEnabled(true)
        lock.lock()

        await lock.setEnabled(false)

        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testPersistedAppLockStartsLockedOnNextLaunch() async {
        let authenticator = MockAppLockAuthenticator()
        let first = AppLockService(defaults: defaults, authenticator: authenticator)
        await first.setEnabled(true)

        let nextLaunch = AppLockService(defaults: defaults, authenticator: authenticator)

        XCTAssertTrue(nextLaunch.isEnabled)
        XCTAssertTrue(nextLaunch.isLocked)
    }

    func testAppLockDisplaysAvailableBiometricType() {
        let authenticator = MockAppLockAuthenticator()
        authenticator.biometryType = .faceID
        let lock = AppLockService(defaults: defaults, authenticator: authenticator)

        XCTAssertEqual(lock.authenticationName, "Face ID")
        authenticator.biometryType = .touchID
        XCTAssertEqual(lock.authenticationName, "Touch ID")
    }

    func testAppearancePreferencesResolveWithoutForcingDarkMode() {
        XCTAssertEqual(ColorSchemePreference.dark.preferredColorScheme, .dark)
        XCTAssertEqual(ColorSchemePreference.light.preferredColorScheme, .light)
        XCTAssertNil(ColorSchemePreference.system.preferredColorScheme)
    }

    func testSolarizedLightProvidesReadableLightChrome() {
        XCTAssertTrue(TerminalTheme.solarizedLight.isLight)
        XCTAssertFalse(TerminalTheme.nord.isLight)

        var backgroundBrightness: CGFloat = 0
        var chromeBrightness: CGFloat = 0
        TerminalTheme.solarizedLight.background.getHue(nil, saturation: nil, brightness: &backgroundBrightness, alpha: nil)
        TerminalTheme.solarizedLight.chromeSurface.getHue(nil, saturation: nil, brightness: &chromeBrightness, alpha: nil)

        XCTAssertLessThan(chromeBrightness, backgroundBrightness)
    }

    private func makeServer(
        name: String,
        favorite: Bool = false,
        connectedAt: TimeInterval? = nil
    ) -> Server {
        let server = Server(
            name: name,
            hostname: "\(name.lowercased()).example.com",
            username: "deploy",
            isFavorite: favorite
        )
        server.lastConnected = connectedAt.map(Date.init(timeIntervalSince1970:))
        return server
    }
}

@MainActor
private final class MockAppLockAuthenticator: AppLockAuthenticating {
    var biometryType: LABiometryType = .faceID
    var available = true
    var shouldThrow = false
    private(set) var authenticationCount = 0

    func canAuthenticate() -> Bool {
        available
    }

    func authenticate(reason: String) async throws -> Bool {
        authenticationCount += 1
        if shouldThrow {
            throw MockAuthenticationError.denied
        }
        return true
    }
}

private enum MockAuthenticationError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Authentication was denied."
    }
}
