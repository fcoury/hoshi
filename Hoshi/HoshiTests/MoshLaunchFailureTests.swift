import XCTest
@testable import Hoshi

final class MoshLaunchFailureTests: XCTestCase {
    /// Captured from a Mac whose Homebrew upgraded abseil underneath mosh.
    private let homebrewDyldOutput = """

    MOSH SSH_CONNECTION 192.168.68.60 52113 192.168.68.150 22
    dyld[29329]: Library not loaded: /opt/homebrew/opt/abseil/lib/libabsl_die_if_null.2601.0.0.dylib
      Referenced from: <B5D2FE19-C052-35DA-A468-A5C4B2FFC73E> /opt/homebrew/Cellar/protobuf/35.1/lib/libprotobuf.35.1.0.dylib
      Reason: tried: '/opt/homebrew/opt/abseil/lib/libabsl_die_if_null.2601.0.0.dylib' (no such file)
    sh: line 1: 29329 Abort trap: 6           /opt/homebrew/bin/mosh-server new -s -c 256

    MOSH SERVER EXIT 134

    """

    func testHomebrewMissingLibraryIsDiagnosedWithAFix() {
        let failure = MoshLaunchFailure(launchOutput: homebrewDyldOutput)
        XCTAssertEqual(failure.kind, .missingLibrary("libabsl_die_if_null.2601.0.0.dylib"))
        XCTAssertEqual(failure.exitCode, 134)
        XCTAssertEqual(failure.suggestedCommand, "brew reinstall mosh")
        XCTAssertFalse(failure.output.contains("MOSH SERVER EXIT"), "Hoshi's markers aren't server output")
        XCTAssertFalse(failure.output.contains("MOSH SSH_CONNECTION"))
        XCTAssertTrue(failure.output.hasPrefix("dyld[29329]: Library not loaded"))
    }

    func testLinuxMissingLibraryHasNoHomebrewFix() {
        let failure = MoshLaunchFailure(launchOutput: """
        mosh-server: error while loading shared libraries: libprotobuf.so.32: cannot open shared object file: No such file or directory

        MOSH SERVER EXIT 127
        """)
        XCTAssertEqual(failure.kind, .missingLibrary("libprotobuf.so.32"))
        XCTAssertNil(failure.suggestedCommand)
    }

    func testOtherLaunchFailures() {
        XCTAssertEqual(MoshLaunchFailure(launchOutput: "sh: mosh-server: command not found\n\nMOSH SERVER EXIT 127").kind, .notFound)
        XCTAssertEqual(MoshLaunchFailure(launchOutput: "sh: 1: /usr/bin/mosh-server: Permission denied\nMOSH SERVER EXIT 126").kind, .permissionDenied)
        XCTAssertEqual(
            MoshLaunchFailure(launchOutput: "mosh-server needs a UTF-8 native locale to run.\n\nMOSH SERVER EXIT 1").kind,
            .localeUnsupported
        )
        XCTAssertEqual(MoshLaunchFailure(launchOutput: "MOSH SERVER EXIT 139").kind, .crashed(signal: 11))
        let unknown = MoshLaunchFailure(launchOutput: "something odd\nMOSH SERVER EXIT 0")
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(unknown.exitCode, 0)
        XCTAssertEqual(MoshLaunchFailure(launchOutput: "", exitCode: 2).exitCode, 2)
    }

    func testLaunchCommandReportsMoshServerStatusInsteadOfFailing() {
        let command = MoshBootstrapService.serverLaunchCommand(
            configuredServerPath: "/opt/homebrew/bin/mosh-server",
            portRange: nil,
            initialCommand: nil
        )
        XCTAssertTrue(command.contains("printf \"\\n\(MoshLaunchFailure.exitMarker) %s\\n\" \"$?\""), command)
        XCTAssertTrue(command.hasSuffix("2>&1"))
    }

    func testPresentationOffersTheFixAndServerOutput() {
        let error = MoshBootstrapError.serverFailedToStart(MoshLaunchFailure(launchOutput: homebrewDyldOutput))
        let presentation = ErrorPresentation.classify(error, context: ErrorContext(hostname: "m5pro.local"))
        XCTAssertEqual(presentation.title, "mosh-server Won't Start")
        XCTAssertEqual(
            presentation.explanation,
            "mosh-server is installed but can't start: a library it needs (libabsl_die_if_null.2601.0.0.dylib) is missing."
        )
        XCTAssertEqual(presentation.suggestedCommand, "brew reinstall mosh")
        XCTAssertTrue(presentation.serverOutput?.contains("Library not loaded") == true)

        // The same details come through when SSH was used instead.
        let fallback = ConnectionFallbackError(moshError: error, sshError: CancellationError())
        XCTAssertEqual(ErrorPresentation.classify(fallback).suggestedCommand, "brew reinstall mosh")
    }
}
