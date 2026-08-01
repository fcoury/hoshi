import Foundation
import UIKit
import XCTest
@testable import Hoshi

@MainActor
final class FileUploadTests: XCTestCase {
    private var rootURL: URL!
    private var staging: FileUploadStagingArea!
    private var backend: MockRemoteFileUploader!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var previousToolbarButtons: [ToolbarButton] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hoshi-file-upload-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        staging = FileUploadStagingArea(rootURL: rootURL.appendingPathComponent("private-staging"))
        backend = MockRemoteFileUploader()
        suiteName = "hoshi.file-upload.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        previousToolbarButtons = ToolbarConfigurationService.shared.loadButtons()
        ToolbarConfigurationService.shared.resetToDefaults()
    }

    override func tearDownWithError() throws {
        ToolbarConfigurationService.shared.saveButtons(previousToolbarButtons)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
        rootURL = nil
        staging = nil
        backend = nil
        suiteName = nil
        defaults = nil
        try super.tearDownWithError()
    }

    func testUploadSizeIsBoundedToOneHundredMiB() {
        XCTAssertEqual(FileUploadPolicy.maximumFileBytes, 100 * 1_024 * 1_024)
        XCTAssertEqual(FileUploadPolicy.chunkBytes, 65_536)
    }

    func testSafeFilenamePreservesUnicodeSpacesAndExtension() throws {
        XCTAssertEqual(try FileUploadPolicy.sanitizeFilename("设计 document ✅.png"), "设计 document ✅.png")
    }

    func testFilenameSeparatorsAndControlCharactersAreNeutralized() throws {
        XCTAssertEqual(try FileUploadPolicy.sanitizeFilename("report/..\\draft\n.png"), "report_.._draft_.png")
    }

    func testFilenameBidirectionalSpoofingCharactersAreNeutralized() throws {
        let spoofed = "safe\u{202E}gnp.exe"

        XCTAssertEqual(try FileUploadPolicy.sanitizeFilename(spoofed), "safe_gnp.exe")
    }

    func testEmptyAndDotFilenamesAreRejected() {
        for filename in ["", "   ", ".", ".."] {
            XCTAssertThrowsError(try FileUploadPolicy.sanitizeFilename(filename)) { error in
                XCTAssertEqual(error as? FileUploadError, .emptyFilename)
            }
        }
    }

    func testLongUnicodeFilenameIsTruncatedAtCharacterBoundaries() throws {
        let name = String(repeating: "界", count: 200)
        let sanitized = try FileUploadPolicy.sanitizeFilename(name)

        XCTAssertLessThanOrEqual(sanitized.utf8.count, FileUploadPolicy.maximumFilenameBytes)
        XCTAssertTrue(sanitized.allSatisfy { $0 == "界" })
    }

    func testUniqueFilenameKeepsOriginalExtensionAndPreventsOverwrites() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

        XCTAssertEqual(try FileUploadPolicy.uniqueFilename("diagram.png", id: id), "diagram-12345678.png")
    }

    func testUniqueFilenameWithoutExtensionStaysWithinSizeLimit() throws {
        let filename = String(repeating: "x", count: 500)

        let unique = try FileUploadPolicy.uniqueFilename(filename, id: UUID())

        XCTAssertLessThanOrEqual(unique.utf8.count, FileUploadPolicy.maximumFilenameBytes)
    }

    func testVeryLongExtensionCannotBypassRemoteFilenameLimit() throws {
        let filename = "a." + String(repeating: "x", count: 400)

        let unique = try FileUploadPolicy.uniqueFilename(filename, id: UUID())

        XCTAssertLessThanOrEqual(unique.utf8.count, FileUploadPolicy.maximumFilenameBytes)
    }

    func testShellQuotingPreservesSpacesDollarSignsAndSemicolons() throws {
        let path = "/home/felipe/project files/$HOME; rm -rf *.png"

        XCTAssertEqual(try FileUploadPolicy.shellQuote(path), "'\(path)'")
    }

    func testShellQuotingEscapesEmbeddedSingleQuotes() throws {
        XCTAssertEqual(
            try FileUploadPolicy.shellQuote("/home/felipe/it's ready.png"),
            "'/home/felipe/it'\\''s ready.png'"
        )
    }

    func testShellQuotingPreservesUnicodeWithoutAddingReturn() throws {
        let value = try FileUploadPolicy.shellQuote("/home/星/ação ✅.heic")

        XCTAssertEqual(value, "'/home/星/ação ✅.heic'")
        XCTAssertFalse(value.contains("\n"))
        XCTAssertFalse(value.contains("\r"))
    }

    func testShellQuotingRejectsRelativeAndControlCharacterPaths() {
        for path in ["relative/file.png", "/home/file\nname", "/home/file\u{0}name"] {
            XCTAssertThrowsError(try FileUploadPolicy.shellQuote(path)) { error in
                XCTAssertEqual(error as? FileUploadError, .invalidRemotePath)
            }
        }
    }

    func testDefaultRemoteDirectoryRemainsInsideHome() throws {
        let directory = try RemoteUploadDirectory(".hoshi/uploads")

        XCTAssertEqual(directory.components, [".hoshi", "uploads"])
        XCTAssertEqual(directory.displayPath, "~/.hoshi/uploads")
    }

    func testTildeAndDotReferToRemoteHome() throws {
        XCTAssertEqual(try RemoteUploadDirectory("~").components, [])
        XCTAssertEqual(try RemoteUploadDirectory(".").components, [])
        XCTAssertEqual(try RemoteUploadDirectory("~/").components, [])
        XCTAssertEqual(try RemoteUploadDirectory("~/screenshots").components, ["screenshots"])
    }

    func testRemoteDirectoryRejectsAbsoluteAndOtherUserPaths() {
        for path in ["/tmp/uploads", "~other/uploads", "~/../../etc"] {
            XCTAssertThrowsError(try RemoteUploadDirectory(path)) { error in
                XCTAssertEqual(error as? FileUploadError, .invalidRemoteDirectory)
            }
        }
    }

    func testRemoteDirectoryRejectsTraversalEmptyAndWindowsComponents() {
        for path in ["../uploads", "safe/../escape", "safe/./escape", "safe//nested", "safe/", "C:\\Windows"] {
            XCTAssertThrowsError(try RemoteUploadDirectory(path))
        }
    }

    func testRemoteDirectoryRejectsControlAndBidirectionalCharacters() {
        for path in ["safe\nuploads", "safe\u{202E}uploads", "safe\u{2066}uploads"] {
            XCTAssertThrowsError(try RemoteUploadDirectory(path))
        }
    }

    func testRemoteDirectoryRejectsOversizedPathsAndComponents() {
        XCTAssertThrowsError(try RemoteUploadDirectory(String(repeating: "a", count: 121)))
        let huge = Array(repeating: String(repeating: "a", count: 100), count: 12).joined(separator: "/")
        XCTAssertThrowsError(try RemoteUploadDirectory(huge))
    }

    func testRemoteDirectoryPreservesSpacesAndShellSpecialCharacters() throws {
        let directory = try RemoteUploadDirectory("my projects/it's $safe")

        XCTAssertEqual(directory.components, ["my projects", "it's $safe"])
    }

    func testHomeBoundaryRejectsPrefixSpoofing() {
        XCTAssertTrue(SFTPFileUploadBackend.isWithinHome("/home/user/uploads", home: "/home/user"))
        XCTAssertFalse(SFTPFileUploadBackend.isWithinHome("/home/user-evil/uploads", home: "/home/user"))
        XCTAssertFalse(SFTPFileUploadBackend.isWithinHome("/tmp/uploads", home: "/home/user"))
    }

    func testRootHomeBuildsCanonicalSingleSlashPaths() {
        XCTAssertEqual(SFTPFileUploadBackend.appending("uploads", to: "/"), "/uploads")
        XCTAssertEqual(SFTPFileUploadBackend.appending("uploads", to: "/home/user"), "/home/user/uploads")
        XCTAssertTrue(SFTPFileUploadBackend.isWithinHome("/uploads", home: "/"))
    }

    func testStagingCopiesDocumentIntoPrivateTemporaryDirectory() async throws {
        let source = try makeSource(name: "notes.txt", data: Data("hello".utf8))

        let file = try await staging.stage(source, kind: .document)

        XCTAssertEqual(file.originalFilename, "notes.txt")
        XCTAssertEqual(file.byteCount, 5)
        XCTAssertEqual(file.kind, .document)
        XCTAssertNotEqual(file.localURL, source)
        XCTAssertEqual(try Data(contentsOf: file.localURL), Data("hello".utf8))
        let remainsStaged = await staging.contains(file)
        XCTAssertTrue(remainsStaged)
    }

    func testStagingPreservesImageFormatAndContents() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let source = try makeSource(name: "screenshot.png", data: bytes)

        let file = try await staging.stage(source, kind: .image)

        XCTAssertEqual(file.kind, .image)
        XCTAssertEqual(file.originalFilename, "screenshot.png")
        XCTAssertEqual(try Data(contentsOf: file.localURL), bytes)
    }

    func testStagingAppliesPrivateFileAndDirectoryPermissions() async throws {
        let source = try makeSource(name: "private.txt", data: Data("secret".utf8))
        let file = try await staging.stage(source, kind: .document)

        let filePermissions = try permissions(at: file.localURL)
        let folderPermissions = try permissions(at: file.localURL.deletingLastPathComponent())

        XCTAssertEqual(filePermissions, 0o600)
        XCTAssertEqual(folderPermissions, 0o700)
    }

    func testStagingRejectsDirectories() async throws {
        let directory = rootURL.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        do {
            _ = try await staging.stage(directory, kind: .document)
            XCTFail("Directory upload should fail")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .invalidSource)
        }
    }

    func testStagingRejectsSymbolicLinks() async throws {
        let target = try makeSource(name: "original.txt", data: Data("source".utf8))
        let link = rootURL.appendingPathComponent("shortcut.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        do {
            _ = try await staging.stage(link, kind: .document)
            XCTFail("Symlink upload should fail")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .symbolicLink)
        }
    }

    func testStagingRejectsNetworkURLs() async {
        do {
            _ = try await staging.stage(URL(string: "https://example.com/file.txt")!, kind: .document)
            XCTFail("Network URLs must not be uploaded directly")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .invalidSource)
        }
    }

    func testOversizedSparseFilesAreRejectedBeforeCopying() async throws {
        let source = try makeSource(name: "too-big.bin", data: Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: FileUploadPolicy.maximumFileBytes + 1)
        try handle.close()

        do {
            _ = try await staging.stage(source, kind: .document)
            XCTFail("Oversized files must not be staged")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .fileTooLarge(maximumBytes: FileUploadPolicy.maximumFileBytes))
        }
    }

    func testEmptyFilesCanBeStagedAndTransferred() async throws {
        let source = try makeSource(name: "empty.txt", data: Data())

        let file = try await staging.stage(source, kind: .document)

        XCTAssertEqual(file.byteCount, 0)
    }

    func testRemovingStagedFileDeletesPrivateFolderWithoutTouchingOriginal() async throws {
        let source = try makeSource(name: "retain.txt", data: Data("original".utf8))
        let file = try await staging.stage(source, kind: .document)

        await staging.remove(file)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.localURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testStagingCleanupRefusesFilesOutsideItsPrivateRoot() async throws {
        let source = try makeSource(name: "outside.txt", data: Data("keep".utf8))
        let fake = StagedUploadFile(id: UUID(), localURL: source, originalFilename: "outside.txt", byteCount: 4, kind: .document)

        await staging.remove(fake)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFileReaderStreamsDataInBoundedChunks() async throws {
        let source = try makeSource(name: "chunks.bin", data: Data("abcdefghij".utf8))
        let reader = try LocalUploadFileReader(url: source)

        let first = try await reader.readChunk(maximumBytes: 4)
        let second = try await reader.readChunk(maximumBytes: 4)
        let third = try await reader.readChunk(maximumBytes: 4)
        let end = try await reader.readChunk(maximumBytes: 4)
        await reader.close()

        XCTAssertEqual(first, Data("abcd".utf8))
        XCTAssertEqual(second, Data("efgh".utf8))
        XCTAssertEqual(third, Data("ij".utf8))
        XCTAssertTrue(end?.isEmpty ?? true)
    }

    func testClosedReaderDoesNotExposeMoreBytes() async throws {
        let source = try makeSource(name: "closed.bin", data: Data("content".utf8))
        let reader = try LocalUploadFileReader(url: source)

        await reader.close()

        let value = try await reader.readChunk(maximumBytes: 10)
        XCTAssertNil(value)
    }

    func testProgressFractionIsBoundedAndEmptyFilesCompleteImmediately() {
        XCTAssertEqual(FileUploadProgress(transferredBytes: 0, totalBytes: 0).fractionCompleted, 1)
        XCTAssertEqual(FileUploadProgress(transferredBytes: 50, totalBytes: 100).fractionCompleted, 0.5)
        XCTAssertEqual(FileUploadProgress(transferredBytes: 101, totalBytes: 100).fractionCompleted, 1)
    }

    func testUploadedRemotePathIsQuotedWithoutReturn() {
        let uploaded = UploadedRemoteFile(
            id: UUID(),
            remotePath: "/home/felipe/it's private.png",
            originalFilename: "it's private.png",
            byteCount: 8,
            kind: .image
        )

        XCTAssertEqual(uploaded.shellQuotedPath, "'/home/felipe/it'\\''s private.png'")
        XCTAssertFalse(uploaded.shellQuotedPath.contains("\n"))
        XCTAssertFalse(uploaded.shellQuotedPath.contains("\r"))
    }

    func testInvalidUploadedRemotePathCannotBeInserted() {
        let uploaded = UploadedRemoteFile(
            id: UUID(),
            remotePath: "relative/path",
            originalFilename: "path",
            byteCount: 1,
            kind: .document
        )

        XCTAssertEqual(uploaded.shellQuotedPath, "")
    }

    func testUploadSettingsDefaultToPrivateDirectoryAndAutomaticInsertion() {
        let settings = FileUploadSettings(defaults: defaults)

        XCTAssertEqual(settings.remoteDirectory, ".hoshi/uploads")
        XCTAssertTrue(settings.insertPathAutomatically)
    }

    func testUploadSettingsPersistConfigurationWithoutFileMetadata() {
        let settings = FileUploadSettings(defaults: defaults)
        settings.remoteDirectory = "project files"
        settings.insertPathAutomatically = false

        let restored = FileUploadSettings(defaults: defaults)
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("app.gethoshi.uploads.") }

        XCTAssertEqual(restored.remoteDirectory, "project files")
        XCTAssertFalse(restored.insertPathAutomatically)
        XCTAssertEqual(keys.count, 2)
    }

    func testDocumentImportCreatesReadyUpload() async throws {
        let source = try makeSource(name: "upload.txt", data: Data("contents".utf8))
        let controller = makeController()

        await controller.importDocument(source)

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.selectedFile?.originalFilename, "upload.txt")
        XCTAssertNil(controller.errorMessage)
        controller.reset()
        await settle()
    }

    func testInvalidDocumentImportProducesActionableError() async {
        let controller = makeController()

        await controller.importDocument(URL(string: "https://example.com/file")!)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.errorMessage, FileUploadError.invalidSource.localizedDescription)
    }

    func testSelectingAnotherFileRemovesPreviousPrivateCopy() async throws {
        let first = try await stage(name: "first.txt", bytes: Data("1".utf8))
        let second = try await stage(name: "second.txt", bytes: Data("2".utf8))
        let controller = makeController()

        await controller.accept(first)
        await controller.accept(second)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.localURL.path))
        XCTAssertEqual(controller.selectedFile?.id, second.id)
        controller.reset()
        await settle()
    }

    func testUploadCannotStartWithoutUserSelectedFile() {
        let controller = makeController()

        controller.startUpload(remoteDirectory: ".hoshi/uploads")

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.errorMessage, FileUploadError.noSelectedFile.localizedDescription)
        XCTAssertEqual(backend.uploadCount, 0)
    }

    func testUnsafeRemoteDirectoryCannotStartTransfer() async throws {
        let controller = makeController()
        let file = try await stage(name: "safe.txt", bytes: Data("ok".utf8))
        await controller.accept(file)

        controller.startUpload(remoteDirectory: "../../etc")

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.errorMessage, FileUploadError.invalidRemoteDirectory.localizedDescription)
        XCTAssertEqual(backend.uploadCount, 0)
        controller.reset()
        await settle()
    }

    func testSuccessfulUploadReportsProgressAndRemovesPrivateCopy() async throws {
        let controller = makeController()
        let file = try await stage(name: "artifact.png", bytes: Data("image".utf8))
        await controller.accept(file)

        controller.startUpload(remoteDirectory: ".hoshi/uploads")
        await settle()

        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.completedFile?.originalFilename, "artifact.png")
        XCTAssertEqual(controller.progress?.fractionCompleted, 1)
        XCTAssertEqual(backend.requestedDirectory?.components, [".hoshi", "uploads"])
        await assertFileRemoved(file)
    }

    func testSuccessfulUploadDoesNotInsertPathWithoutExplicitUIAction() async throws {
        let controller = makeController()
        let file = try await stage(name: "manual.txt", bytes: Data("ok".utf8))
        await controller.accept(file)

        controller.startUpload(remoteDirectory: "uploads")
        await settle()

        XCTAssertEqual(controller.state, .completed)
        XCTAssertFalse(controller.pathWasInserted)
        controller.markPathInserted()
        XCTAssertTrue(controller.pathWasInserted)
    }

    func testMarkingPathInsertedRequiresCompletedUpload() {
        let controller = makeController()

        controller.markPathInserted()

        XCTAssertFalse(controller.pathWasInserted)
    }

    func testTransferFailureClearsUnusableStagedSelection() async throws {
        backend.failure = FileUploadError.uploadFailed("Permission denied")
        let controller = makeController()
        let file = try await stage(name: "blocked.txt", bytes: Data("x".utf8))
        await controller.accept(file)

        controller.startUpload(remoteDirectory: "uploads")
        await settle()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.errorMessage?.contains("Permission denied") == true)
        XCTAssertNil(controller.selectedFile)
        await assertFileRemoved(file)
    }

    func testCancelingUploadRemovesSelectionAndPrivateCopy() async throws {
        backend.waitForCancellation = true
        let controller = makeController()
        let file = try await stage(name: "cancel.bin", bytes: Data("bytes".utf8))
        await controller.accept(file)
        controller.startUpload(remoteDirectory: "uploads")
        await settle()

        controller.cancel()
        await settle()

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertNil(controller.selectedFile)
        XCTAssertNil(controller.completedFile)
        await assertFileRemoved(file)
    }

    func testResetCancelsActiveTransferAndErasesAllMetadata() async throws {
        backend.waitForCancellation = true
        let controller = makeController()
        let file = try await stage(name: "secret.bin", bytes: Data("private".utf8))
        await controller.accept(file)
        controller.startUpload(remoteDirectory: "uploads")
        await settle()

        controller.reset()
        await settle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.selectedFile)
        XCTAssertNil(controller.completedFile)
        XCTAssertNil(controller.progress)
        XCTAssertNil(controller.errorMessage)
        await assertFileRemoved(file)
    }

    func testDoubleUploadCannotStartSecondTransfer() async throws {
        backend.waitForCancellation = true
        let controller = makeController()
        let file = try await stage(name: "once.bin", bytes: Data("x".utf8))
        await controller.accept(file)

        controller.startUpload(remoteDirectory: "uploads")
        await settle()
        controller.startUpload(remoteDirectory: "uploads")

        XCTAssertEqual(backend.uploadCount, 1)
        XCTAssertEqual(controller.state, .uploading)
        controller.reset()
        await settle()
    }

    func testDocumentImportCannotInterruptActiveUpload() async throws {
        backend.waitForCancellation = true
        let controller = makeController()
        let activeFile = try await stage(name: "active.bin", bytes: Data("x".utf8))
        let replacement = try makeSource(name: "replacement.bin", data: Data("new".utf8))
        await controller.accept(activeFile)
        controller.startUpload(remoteDirectory: "uploads")
        await settle()

        await controller.importDocument(replacement)

        XCTAssertEqual(controller.state, .uploading)
        XCTAssertEqual(controller.selectedFile?.id, activeFile.id)
        XCTAssertEqual(backend.uploadCount, 1)
        controller.reset()
        await assertFileRemoved(activeFile)
    }

    func testLateProgressCannotRestoreCanceledTransferState() async throws {
        backend.waitForCancellation = true
        let controller = makeController()
        let file = try await stage(name: "late.bin", bytes: Data("12345".utf8))
        await controller.accept(file)
        controller.startUpload(remoteDirectory: "uploads")
        await settle()
        let callback = backend.progressCallback

        controller.cancel()
        callback?(FileUploadProgress(transferredBytes: 5, totalBytes: 5))
        await settle()

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertNil(controller.progress)
        XCTAssertNil(controller.completedFile)
    }

    func testPrivacyCoordinatorClearsUploadOnBackgroundOrAppLock() async throws {
        let coordinator = FileUploadPrivacyCoordinator()
        let controller = makeController()
        let file = try await stage(name: "private.png", bytes: Data("photo".utf8))
        await controller.accept(file)
        coordinator.activate(controller)

        coordinator.protectSensitiveContent()
        await settle()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.selectedFile)
        await assertFileRemoved(file)
    }

    func testSwitchingUploadControllersClearsPreviousSessionSelection() async throws {
        let coordinator = FileUploadPrivacyCoordinator()
        let first = makeController()
        let file = try await stage(name: "first-session.txt", bytes: Data("sensitive".utf8))
        await first.accept(file)
        let second = FileUploadController(backend: MockRemoteFileUploader(), staging: staging)

        coordinator.activate(first)
        coordinator.activate(second)
        await settle()

        XCTAssertEqual(first.state, .idle)
        XCTAssertNil(first.selectedFile)
        await assertFileRemoved(file)
    }

    func testDeactivatingUnrelatedUploadControllerPreservesActiveSelection() async throws {
        let coordinator = FileUploadPrivacyCoordinator()
        let active = makeController()
        let file = try await stage(name: "active.txt", bytes: Data("keep".utf8))
        await active.accept(file)
        let unrelated = FileUploadController(backend: MockRemoteFileUploader(), staging: staging)
        coordinator.activate(active)

        coordinator.deactivate(unrelated)

        XCTAssertEqual(active.selectedFile?.id, file.id)
        active.reset()
        await settle()
    }

    func testDisconnectedSessionHasNoFileTransferClient() {
        let connection = ConnectionViewModel()

        XCTAssertNil(connection.fileTransferConnectionSource)
    }

    func testMoshConnectionUsesFreshVerifiedSSHAfterBootstrapCloses() {
        let connection = ConnectionViewModel()
        let session = MoshSession(server: makeServer())
        session.connectionState = .connected
        connection.moshSession = session

        XCTAssertEqual(connection.fileTransferConnectionSource, .verifiedMoshReconnect)
    }

    func testMoshTransferFailsClosedWithoutStoredPassword() async {
        let connection = ConnectionViewModel()
        let session = MoshSession(server: makeServer())
        session.connectionState = .connected
        connection.moshSession = session

        do {
            let _: String = try await connection.withVerifiedFileTransferClient { _ in "unexpected" }
            XCTFail("Transfer should not connect without verified credentials")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .missingCredentials)
        }
    }

    func testDisconnectedMoshTransferCannotOpenSecondarySSH() async {
        let connection = ConnectionViewModel()
        let session = MoshSession(server: makeServer())
        connection.moshSession = session

        do {
            let _: String = try await connection.withVerifiedFileTransferClient { _ in "unexpected" }
            XCTFail("Disconnected sessions must not upload")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .disconnected)
        }
    }

    func testKeyAuthenticatedMoshRequiresExplicitSelectedKey() async {
        let connection = ConnectionViewModel()
        let server = Server(name: "Key", hostname: "unit-test.invalid", username: "tester", authMethod: .key, useMosh: true)
        let session = MoshSession(server: server)
        session.connectionState = .connected
        connection.moshSession = session

        do {
            let _: String = try await connection.withVerifiedFileTransferClient { _ in "unexpected" }
            XCTFail("A key-authenticated transfer must not choose an arbitrary key")
        } catch {
            XCTAssertEqual(error as? FileUploadError, .missingCredentials)
        }
    }

    func testDefaultToolbarExposesAccessibleFileTransferAction() {
        XCTAssertTrue(ToolbarButton.defaultButtons.contains(.uploadFile))
        XCTAssertTrue(ToolbarButton.allAvailable.contains(.uploadFile))
        XCTAssertEqual(ToolbarButton.uploadFile.accessibilityLabel, "Upload a file or photo securely")
        XCTAssertEqual(ToolbarButton.uploadFile.category, .transfer)
    }

    func testLegacyToolbarWithoutFileActionMigratesToNewDefault() {
        let previous = ToolbarButton.defaultButtons.filter { $0 != .uploadFile }
        ToolbarConfigurationService.shared.saveButtons(previous)

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), ToolbarButton.defaultButtons)
    }

    func testLegacyToolbarWithoutPasteVoiceOrUploadMigratesToNewDefault() {
        let previous = ToolbarButton.defaultButtons.filter {
            $0 != .paste && $0 != .voicePrompt && $0 != .uploadFile
        }
        ToolbarConfigurationService.shared.saveButtons(previous)

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), ToolbarButton.defaultButtons)
    }

    func testCustomizedToolbarWithoutFileActionIsPreserved() {
        ToolbarConfigurationService.shared.saveButtons([.ctrl, .paste, .voicePrompt])

        XCTAssertEqual(ToolbarConfigurationService.shared.loadButtons(), [.ctrl, .paste, .voicePrompt])
    }

    func testFileToolbarActionOpensPickerWithoutSendingTerminalBytes() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .uploadFile])
        var opened = 0
        var sent: [[UInt8]] = []
        toolbar.onFileUpload = { opened += 1 }
        toolbar.onButtonTap = { sent.append($0) }

        toolbar.handleButtonTap(.uploadFile)

        XCTAssertEqual(opened, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testFileToolbarActionPreservesStickyModifiers() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.ctrl, .uploadFile])
        toolbar.onFileUpload = {}

        toolbar.handleButtonTap(.ctrl)
        toolbar.handleButtonTap(.uploadFile)

        XCTAssertEqual(toolbar.activeModifiers, ["ctrl"])
    }

    func testFileToolbarActionDoesNotChangeAccessoryHeight() {
        let toolbar = KeyboardToolbarAccessoryView(buttons: [.uploadFile, .voicePrompt])

        XCTAssertEqual(toolbar.intrinsicContentSize.height, KeyboardToolbarAccessoryView.preferredHeight)
        XCTAssertGreaterThanOrEqual(toolbar.intrinsicContentSize.height, 44)
    }

    func testGhosttySurfaceRoutesUploadActionWithoutChangingKeyboardVisibility() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: true)
        var opened = false
        surface.onFileUpload = { opened = true }

        surface.toolbarAccessory.handleButtonTap(.uploadFile)

        XCTAssertTrue(opened)
        XCTAssertTrue(surface.isKeyboardVisible)
    }

    func testKeyboardVisibilityCanBeRestoredAfterUploadSheet() {
        let surface = GhosttyTerminalSurfaceView(app: nil, fontSize: 14, keyboardVisible: true)

        surface.setKeyboardVisible(false)
        surface.setKeyboardVisible(true)

        XCTAssertTrue(surface.isKeyboardVisible)
    }

    func testUploadErrorMessagesNeverContainLocalFileContents() {
        XCTAssertTrue(FileUploadError.disconnected.localizedDescription.contains("Reconnect"))
        XCTAssertTrue(FileUploadError.invalidRemoteDirectory.localizedDescription.contains("home"))
        XCTAssertTrue(FileUploadError.missingCredentials.localizedDescription.contains("credentials"))
    }

    private func makeController() -> FileUploadController {
        FileUploadController(backend: backend, staging: staging)
    }

    private func makeSource(name: String, data: Data) throws -> URL {
        let source = rootURL.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: source.path, contents: data) else {
            throw FileUploadError.invalidSource
        }
        return source
    }

    private func stage(name: String, bytes: Data) async throws -> StagedUploadFile {
        try await staging.stage(try makeSource(name: name, data: bytes), kind: .document)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func makeServer() -> Server {
        Server(name: "Upload Test", hostname: "upload-test.invalid", username: "tester", useMosh: true)
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func assertFileRemoved(
        _ stagedFile: StagedUploadFile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: stagedFile.localURL.path) {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The private staged file was not removed", file: file, line: line)
    }
}

@MainActor
private final class MockRemoteFileUploader: RemoteFileUploading {
    var uploadCount = 0
    var failure: (any Error)?
    var waitForCancellation = false
    var requestedDirectory: RemoteUploadDirectory?
    var progressCallback: (@Sendable (FileUploadProgress) -> Void)?

    func upload(
        _ file: StagedUploadFile,
        to directory: RemoteUploadDirectory,
        progress: @escaping @Sendable (FileUploadProgress) -> Void
    ) async throws -> UploadedRemoteFile {
        uploadCount += 1
        requestedDirectory = directory
        progressCallback = progress
        progress(FileUploadProgress(transferredBytes: 0, totalBytes: file.byteCount))

        if waitForCancellation {
            try await Task.sleep(for: .seconds(60))
        }

        if let failure {
            throw failure
        }

        progress(FileUploadProgress(transferredBytes: file.byteCount, totalBytes: file.byteCount))
        return UploadedRemoteFile(
            id: file.id,
            remotePath: "/home/tester/\(directory.components.joined(separator: "/"))/\(file.remoteFilename)",
            originalFilename: file.originalFilename,
            byteCount: file.byteCount,
            kind: file.kind
        )
    }
}
