import Foundation
import XCTest
@testable import Hoshi

@MainActor
final class RemoteFileBrowserTests: XCTestCase {
    private var rootURL: URL!
    private var staging: RemoteFileDownloadStagingArea!
    private var backend: MockRemoteFileBrowser!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hoshi-file-browser-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        staging = RemoteFileDownloadStagingArea(rootURL: rootURL.appendingPathComponent("private-downloads"))
        backend = MockRemoteFileBrowser()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        rootURL = nil
        staging = nil
        backend = nil
        try super.tearDownWithError()
    }

    func testRemoteHomeMustBeCanonicalAndAbsolute() throws {
        XCTAssertEqual(try RemoteFileBrowserPolicy.validateHome("/home/felipe"), "/home/felipe")
        XCTAssertEqual(try RemoteFileBrowserPolicy.validateHome("/"), "/")

        for path in ["home/felipe", "/home//felipe", "/home/../root", "/home/./felipe", "/home/a\n"] {
            XCTAssertThrowsError(try RemoteFileBrowserPolicy.validateHome(path)) { error in
                XCTAssertEqual(error as? RemoteFileBrowserError, .invalidHomeDirectory)
            }
        }
    }

    func testRemoteEntryNameRejectsTraversalSeparatorsAndInvisibleControls() {
        for name in ["", ".", "..", "../secret", "safe/file", "safe\\file", "line\nbreak", "spoof\u{202E}txt"] {
            XCTAssertThrowsError(try RemoteFileBrowserPolicy.validateEntryName(name))
        }
        XCTAssertThrowsError(try RemoteFileBrowserPolicy.validateEntryName(String(repeating: "a", count: 181)))
    }

    func testRemoteEntryNamePreservesUnicodeSpacesAndShellCharacters() throws {
        try RemoteFileBrowserPolicy.validateEntryName("设计 notes $HOME ✅.md")
    }

    func testRemoteFileKindsAreDetectedFromPOSIXFileModes() {
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: 0o040755, longname: ""), .directory)
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: 0o100644, longname: ""), .regularFile)
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: 0o120777, longname: ""), .symbolicLink)
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: 0o060600, longname: ""), .other)
    }

    func testRemoteFileKindsFallBackToLongListingWhenModeIsMissing() {
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: nil, longname: "drwxr-xr-x"), .directory)
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: 0o644, longname: "-rw-r--r--"), .regularFile)
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: nil, longname: "lrwxrwxrwx"), .symbolicLink)
        XCTAssertEqual(RemoteFileBrowserPolicy.classify(permissions: nil, longname: "srwxr-xr-x"), .other)
    }

    func testFoldersSortBeforeFilesUsingNaturalNames() throws {
        let directory = try RemoteUploadDirectory("~")
        let entries = [
            entry("file10.txt", in: directory),
            entry("Zebra", in: directory, kind: .directory),
            entry("file2.txt", in: directory),
            entry("agents", in: directory, kind: .directory),
        ]

        XCTAssertEqual(
            RemoteFileBrowserPolicy.sorted(entries).map(\.name),
            ["agents", "Zebra", "file2.txt", "file10.txt"]
        )
    }

    func testDirectoryNavigationCannotEscapeRemoteHome() throws {
        let home = try RemoteUploadDirectory("~")
        let project = try RemoteFileBrowserPolicy.childDirectory(named: "project files", in: home)
        let nested = try RemoteFileBrowserPolicy.childDirectory(named: "src", in: project)

        XCTAssertEqual(project.displayPath, "~/project files")
        XCTAssertEqual(nested.displayPath, "~/project files/src")
        XCTAssertEqual(try RemoteFileBrowserPolicy.parentDirectory(of: nested), project)
        XCTAssertEqual(try RemoteFileBrowserPolicy.parentDirectory(of: project), home)
        XCTAssertNil(try RemoteFileBrowserPolicy.parentDirectory(of: home))
        XCTAssertThrowsError(try RemoteFileBrowserPolicy.childDirectory(named: "..", in: home))
    }

    func testDirectoryAndDownloadSizesAreBounded() {
        XCTAssertEqual(RemoteFileBrowserPolicy.maximumDirectoryEntries, 2_000)
        XCTAssertEqual(RemoteFileBrowserPolicy.maximumDownloadBytes, 100 * 1_024 * 1_024)
        XCTAssertEqual(RemoteFileBrowserPolicy.downloadChunkBytes, 65_536)
    }

    func testDownloadProgressHandlesKnownUnknownAndEmptySizes() {
        XCTAssertEqual(RemoteFileDownloadProgress(transferredBytes: 5, totalBytes: 10).fractionCompleted, 0.5)
        XCTAssertEqual(RemoteFileDownloadProgress(transferredBytes: 20, totalBytes: 10).fractionCompleted, 1)
        XCTAssertNil(RemoteFileDownloadProgress(transferredBytes: 5, totalBytes: nil).fractionCompleted)
        XCTAssertNil(RemoteFileDownloadProgress(transferredBytes: 0, totalBytes: 0).fractionCompleted)
    }

    func testPrivateDownloadStagingUsesRestrictedDirectoriesAndFiles() async throws {
        let item = entry("secret notes.txt")
        let pending = try await staging.prepare(item)
        XCTAssertEqual(try permissions(at: pending.finalURL.deletingLastPathComponent()), 0o700)

        guard FileManager.default.createFile(
            atPath: pending.partialURL.path,
            contents: Data("private".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            return XCTFail("Could not create staged file")
        }

        let downloaded = try await staging.complete(pending, byteCount: 7)

        XCTAssertEqual(downloaded.originalFilename, "secret notes.txt")
        XCTAssertEqual(downloaded.remotePath, "~/secret notes.txt")
        XCTAssertEqual(downloaded.byteCount, 7)
        XCTAssertEqual(try Data(contentsOf: downloaded.localURL), Data("private".utf8))
        XCTAssertEqual(try permissions(at: downloaded.localURL), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.partialURL.path))
    }

    func testPrivateDownloadStagingRejectsMaliciousNames() async {
        for name in ["../secret", "safe/name", "spoof\u{202E}txt"] {
            do {
                _ = try await staging.prepare(entry(name))
                XCTFail("Unsafe filename \(name) should not be staged")
            } catch {
                XCTAssertTrue(error is RemoteFileBrowserError)
            }
        }
    }

    func testRemovingCompletedDownloadErasesOnlyItsPrivateDirectory() async throws {
        let pending = try await staging.prepare(entry("artifact.txt"))
        guard FileManager.default.createFile(atPath: pending.partialURL.path, contents: Data("ok".utf8)) else {
            return XCTFail("Could not create staged file")
        }
        let file = try await staging.complete(pending, byteCount: 2)
        let unrelated = rootURL.appendingPathComponent("keep.txt")
        guard FileManager.default.createFile(atPath: unrelated.path, contents: Data("keep".utf8)) else {
            return XCTFail("Could not create unrelated file")
        }

        await staging.remove(file)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testBrowserLoadsAndSortsDirectoryEntries() async throws {
        backend.entries = [entry("notes.txt"), entry("project", kind: .directory)]
        let controller = makeController()

        controller.load()
        await settle(controller)

        XCTAssertFalse(controller.isLoading)
        XCTAssertEqual(controller.currentDirectory.displayPath, "~")
        XCTAssertEqual(controller.entries.map(\.name), ["project", "notes.txt"])
        XCTAssertNil(controller.presentedError)
    }

    func testBrowserNavigatesIntoFoldersAndBackHome() async throws {
        let folder = entry("projects", kind: .directory)
        backend.entries = [folder]
        let controller = makeController()
        controller.load()
        await settle(controller)

        backend.entries = [entry("main.swift", in: try RemoteUploadDirectory("projects"))]
        controller.openDirectory(folder)
        await settle(controller)

        XCTAssertEqual(controller.currentDirectory.displayPath, "~/projects")
        XCTAssertEqual(backend.requestedDirectories.last?.components, ["projects"])
        XCTAssertTrue(controller.canNavigateUp)

        backend.entries = [folder]
        controller.navigateUp()
        await settle(controller)

        XCTAssertEqual(controller.currentDirectory.displayPath, "~")
        XCTAssertFalse(controller.canNavigateUp)
    }

    func testBrowserBreadcrumbNavigationUsesSafeRelativeComponents() async throws {
        let controller = RemoteFileBrowserController(
            backend: backend,
            staging: staging,
            directory: try RemoteUploadDirectory("projects/hoshi/src")
        )

        controller.navigate(to: ["projects", "hoshi"])
        await settle(controller)

        XCTAssertEqual(controller.currentDirectory.displayPath, "~/projects/hoshi")

        controller.navigate(to: ["..", "private"])
        XCTAssertEqual(controller.presentedError?.title, "Invalid Upload Destination")
        XCTAssertEqual(controller.currentDirectory.displayPath, "~/projects/hoshi")
    }

    func testSymlinkAndUnsupportedEntriesCannotBeOpened() {
        let controller = makeController()

        controller.openDirectory(entry("escape", kind: .symbolicLink))
        XCTAssertEqual(controller.presentedError?.title, "Unsafe Remote File Path Blocked")

        controller.download(entry("socket", kind: .other))
        XCTAssertEqual(controller.presentedError?.title, "Unsupported Remote File")
        XCTAssertEqual(backend.downloadCount, 0)
    }

    func testOversizedDownloadsAreRejectedBeforeRemoteAccess() {
        let controller = makeController()
        let oversized = entry(
            "huge.bin",
            size: RemoteFileBrowserPolicy.maximumDownloadBytes + 1
        )

        controller.download(oversized)

        XCTAssertEqual(controller.presentedError?.title, "File Exceeds Download Limit")
        XCTAssertEqual(backend.downloadCount, 0)
        XCTAssertFalse(controller.isDownloading)
    }

    func testSuccessfulDownloadReportsProgressAndProvidesPrivateFile() async throws {
        backend.downloadContents = Data("hello from server".utf8)
        let file = entry("notes.txt", size: UInt64(backend.downloadContents.count))
        let controller = makeController()

        controller.download(file)
        await settle(controller)

        let downloaded = try XCTUnwrap(controller.downloadedFile)
        XCTAssertFalse(controller.isDownloading)
        XCTAssertEqual(controller.downloadProgress?.fractionCompleted, 1)
        XCTAssertEqual(downloaded.originalFilename, "notes.txt")
        XCTAssertEqual(try Data(contentsOf: downloaded.localURL), backend.downloadContents)
        XCTAssertEqual(try permissions(at: downloaded.localURL), 0o600)
        controller.reset()
        await assertFileRemoved(downloaded.localURL)
    }

    func testEmptyRemoteFilesCanBeDownloaded() async throws {
        backend.downloadContents = Data()
        let controller = makeController()

        controller.download(entry("empty.txt", size: 0))
        await settle(controller)

        let file = try XCTUnwrap(controller.downloadedFile)
        XCTAssertEqual(file.byteCount, 0)
        XCTAssertEqual(try Data(contentsOf: file.localURL), Data())
        controller.reset()
        await assertFileRemoved(file.localURL)
    }

    func testClearingDownloadedFileErasesPrivateCopy() async throws {
        let controller = makeController()
        controller.download(entry("secret.txt", size: UInt64(backend.downloadContents.count)))
        await settle(controller)
        let file = try XCTUnwrap(controller.downloadedFile)

        controller.clearDownloadedFile()

        XCTAssertNil(controller.downloadedFile)
        await assertFileRemoved(file.localURL)
    }

    func testCancelingDownloadRemovesIncompletePrivateFile() async throws {
        backend.waitForCancellation = true
        let controller = makeController()
        controller.download(entry("slow.bin", size: 10))
        await settle(controller)
        let partial = try XCTUnwrap(backend.destination)

        controller.cancelDownload()
        await settle(controller)

        XCTAssertFalse(controller.isDownloading)
        XCTAssertNil(controller.downloadedFile)
        XCTAssertNil(controller.downloadProgress)
        await assertFileRemoved(partial)
    }

    func testSecondDownloadCannotInterruptAnActiveTransfer() async {
        backend.waitForCancellation = true
        let controller = makeController()
        controller.download(entry("first.bin", size: 10))
        await settle(controller)

        controller.download(entry("second.bin", size: 10))

        XCTAssertEqual(backend.downloadCount, 1)
        XCTAssertEqual(controller.presentedError?.title, "Download Already in Progress")
        XCTAssertTrue(controller.isDownloading)
        controller.reset()
        await settle(controller)
    }

    func testFailedDownloadCleansPrivateDataAndDisclosesUnderlyingCause() async {
        backend.failure = NSError(
            domain: "HoshiTests.SFTP",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Remote permission denied"]
        )
        let controller = makeController()

        controller.download(entry("private.txt"))
        await settle(controller)

        XCTAssertFalse(controller.isDownloading)
        XCTAssertNil(controller.downloadedFile)
        XCTAssertTrue(controller.presentedError?.technicalDetails.contains("HoshiTests.SFTP") == true)
        XCTAssertTrue(controller.presentedError?.technicalDetails.contains("Code: 13") == true)
        if let partial = backend.destination {
            await assertFileRemoved(partial)
        }
    }

    func testFailedDirectoryListingPreservesCurrentDirectory() async throws {
        let controller = RemoteFileBrowserController(
            backend: backend,
            staging: staging,
            directory: try RemoteUploadDirectory("projects")
        )
        backend.failure = RemoteFileBrowserError.unsafeRemotePath

        controller.load(try RemoteUploadDirectory("other"))
        await settle(controller)

        XCTAssertEqual(controller.currentDirectory.displayPath, "~/projects")
        XCTAssertFalse(controller.isLoading)
        XCTAssertEqual(controller.presentedError?.title, "Unsafe Remote File Path Blocked")
    }

    func testOversizedDirectoryListingIsRejectedBeforeRendering() async {
        backend.entries = (0...RemoteFileBrowserPolicy.maximumDirectoryEntries).map { index in
            entry("file-\(index).txt")
        }
        let controller = makeController()

        controller.load()
        await settle(controller)

        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertEqual(controller.presentedError?.title, "Remote Folder Is Too Large")
    }

    func testResetCancelsOperationsAndErasesDownloadedMetadata() async throws {
        let controller = makeController()
        controller.download(entry("private.txt"))
        await settle(controller)
        let file = try XCTUnwrap(controller.downloadedFile)

        controller.reset()

        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertNil(controller.downloadedFile)
        XCTAssertNil(controller.downloadProgress)
        XCTAssertNil(controller.presentedError)
        await assertFileRemoved(file.localURL)
    }

    func testPrivacyCoordinatorRemovesPrivateDownloads() async throws {
        let controller = makeController()
        controller.download(entry("private.txt"))
        await settle(controller)
        let file = try XCTUnwrap(controller.downloadedFile)
        let privacy = RemoteFileBrowserPrivacyCoordinator()
        privacy.activate(controller)

        privacy.protectSensitiveContent()

        XCTAssertNil(controller.downloadedFile)
        await assertFileRemoved(file.localURL)
    }

    func testSwitchingBrowsersClearsPreviousPrivateDownloads() async throws {
        let first = makeController()
        first.download(entry("first.txt"))
        await settle(first)
        let file = try XCTUnwrap(first.downloadedFile)
        let second = RemoteFileBrowserController(backend: MockRemoteFileBrowser(), staging: staging)
        let privacy = RemoteFileBrowserPrivacyCoordinator()
        privacy.activate(first)

        privacy.activate(second)

        XCTAssertNil(first.downloadedFile)
        await assertFileRemoved(file.localURL)
    }

    func testRemoteBrowserErrorsContainSafeActionableGuidance() {
        let symlink = ErrorPresentation.classify(
            RemoteFileBrowserError.symbolicLink("outside"),
            context: ErrorContext(operation: .fileBrowser)
        )
        XCTAssertEqual(symlink.title, "Unsafe Remote File Path Blocked")
        XCTAssertTrue(symlink.recoverySuggestion?.contains("home directory") == true)
        XCTAssertTrue(symlink.diagnostics.exactError.contains("symbolicLink"))

        let missing = ErrorPresentation.classify(
            RemoteFileBrowserError.disconnected,
            context: ErrorContext(operation: .fileBrowser)
        )
        XCTAssertEqual(missing.title, "File Browser Requires an SSH Connection")
    }

    func testSFTPBrowserFailsClosedWhenTerminalIsDisconnected() async throws {
        let backend = SFTPRemoteFileBrowserBackend(connection: ConnectionViewModel())

        do {
            _ = try await backend.list(RemoteUploadDirectory("~"))
            XCTFail("A disconnected terminal must not open a file-transfer connection")
        } catch {
            XCTAssertEqual(error as? RemoteFileBrowserError, .disconnected)
        }
    }

    func testMoshBrowserRequiresVerifiedSavedCredentials() async throws {
        let connection = ConnectionViewModel()
        let server = Server(name: "Mosh", hostname: "unit-test.invalid", username: "tester", useMosh: true)
        let session = MoshSession(server: server)
        session.connectionState = .connected
        connection.moshSession = session
        let backend = SFTPRemoteFileBrowserBackend(connection: connection)

        do {
            _ = try await backend.list(RemoteUploadDirectory("~"))
            XCTFail("A Mosh browser must not connect without verified SSH credentials")
        } catch {
            XCTAssertEqual(error as? RemoteFileBrowserError, .missingCredentials)
        }
    }

    private func makeController() -> RemoteFileBrowserController {
        RemoteFileBrowserController(backend: backend, staging: staging)
    }

    private func entry(
        _ name: String,
        in directory: RemoteUploadDirectory? = nil,
        kind: RemoteFileKind = .regularFile,
        size: UInt64? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            directory: directory ?? (try! RemoteUploadDirectory("~")),
            kind: kind,
            byteCount: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func settle(_ controller: RemoteFileBrowserController) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            await Task.yield()
            if controller.isLoading { continue }
            if controller.isDownloading {
                if backend.waitForCancellation, backend.destination != nil {
                    return
                }
                continue
            }
            return
        }
        XCTFail("The file-browser operation did not settle")
    }

    private func assertFileRemoved(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The private downloaded file was not removed", file: file, line: line)
    }
}

@MainActor
private final class MockRemoteFileBrowser: RemoteFileBrowsing {
    var entries: [RemoteFileEntry] = []
    var requestedDirectories: [RemoteUploadDirectory] = []
    var downloadCount = 0
    var downloadContents = Data("remote file contents".utf8)
    var destination: URL?
    var failure: (any Error)?
    var waitForCancellation = false

    func list(_ directory: RemoteUploadDirectory) async throws -> [RemoteFileEntry] {
        requestedDirectories.append(directory)
        if let failure { throw failure }
        return entries
    }

    func download(
        _ entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (RemoteFileDownloadProgress) -> Void
    ) async throws -> UInt64 {
        downloadCount += 1
        self.destination = destination
        let total = UInt64(downloadContents.count)
        progress(RemoteFileDownloadProgress(transferredBytes: 0, totalBytes: total))

        if waitForCancellation {
            guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
                throw RemoteFileBrowserError.localFileUnavailable
            }
            try await Task.sleep(for: .seconds(60))
        }

        if let failure { throw failure }
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: downloadContents,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw RemoteFileBrowserError.localFileUnavailable
        }
        progress(RemoteFileDownloadProgress(transferredBytes: total, totalBytes: total))
        return total
    }
}
