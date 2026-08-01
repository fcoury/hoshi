import Citadel
import CoreTransferable
import Foundation
import NIOCore
import UniformTypeIdentifiers

enum FileUploadError: LocalizedError, Equatable {
    case disconnected
    case missingCredentials
    case invalidSource
    case symbolicLink
    case emptyFilename
    case fileTooLarge(maximumBytes: UInt64)
    case invalidRemoteDirectory
    case unsafeRemoteDirectory
    case invalidRemotePath
    case noSelectedFile
    case uploadInProgress
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            "Reconnect to this server before uploading a file."
        case .missingCredentials:
            "This connection no longer has its verified SSH credentials. Reconnect and try again."
        case .invalidSource:
            "Choose a regular file or image that is available on this device."
        case .symbolicLink:
            "Symbolic links cannot be uploaded. Choose the original file instead."
        case .emptyFilename:
            "Choose a file with a valid name."
        case .fileTooLarge(let maximumBytes):
            "Files must be no larger than \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))."
        case .invalidRemoteDirectory:
            "Choose a relative directory inside your remote home folder, without parent-directory references."
        case .unsafeRemoteDirectory:
            "The upload directory resolves outside your remote home or follows a symbolic link."
        case .invalidRemotePath:
            "The remote server returned an unsafe upload path."
        case .noSelectedFile:
            "Choose a file or image before starting an upload."
        case .uploadInProgress:
            "An upload is already in progress."
        case .uploadFailed(let reason):
            "Upload failed: \(reason)"
        }
    }
}

enum FileUploadKind: String, Codable, Equatable, Sendable {
    case document
    case image

    var systemImage: String {
        switch self {
        case .document: "doc"
        case .image: "photo"
        }
    }
}

enum FileUploadPolicy {
    static let maximumFileBytes: UInt64 = 100 * 1_024 * 1_024
    static let maximumDirectoryBytes = 1_024
    static let maximumDirectoryComponentBytes = 120
    static let maximumFilenameBytes = 180
    static let chunkBytes = 65_536

    private static let bidirectionalControlScalars: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || bidirectionalControlScalars.contains(scalar.value)
        }
    }

    static func sanitizeFilename(_ raw: String) throws -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            if scalar == "/" || scalar == "\\"
                || CharacterSet.controlCharacters.contains(scalar)
                || bidirectionalControlScalars.contains(scalar.value) {
                return "_"
            }
            return scalar
        })).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            throw FileUploadError.emptyFilename
        }
        return truncate(cleaned, maximumBytes: maximumFilenameBytes)
    }

    static func uniqueFilename(_ filename: String, id: UUID) throws -> String {
        let cleaned = try sanitizeFilename(filename)
        let suffix = "-\(id.uuidString.prefix(8).lowercased())"
        let extensionName = (cleaned as NSString).pathExtension
        let stem: String
        let extensionSuffix: String

        if extensionName.isEmpty {
            stem = cleaned
            extensionSuffix = ""
        } else {
            let extensionBudget = max(0, maximumFilenameBytes - suffix.utf8.count - 2)
            extensionSuffix = "." + truncate(extensionName, maximumBytes: extensionBudget)
            stem = (cleaned as NSString).deletingPathExtension
        }

        let budget = max(1, maximumFilenameBytes - suffix.utf8.count - extensionSuffix.utf8.count)
        return truncate(stem, maximumBytes: budget) + suffix + extensionSuffix
    }

    static func shellQuote(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !containsUnsafeCharacters(path), !path.contains("\u{0}") else {
            throw FileUploadError.invalidRemotePath
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func truncate(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }

        var result = ""
        var count = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard count + bytes <= maximumBytes else { break }
            result.append(character)
            count += bytes
        }
        return result
    }
}

struct RemoteUploadDirectory: Equatable, Sendable {
    let components: [String]

    init(_ raw: String) throws {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= FileUploadPolicy.maximumDirectoryBytes else {
            throw FileUploadError.invalidRemoteDirectory
        }

        if value == "~" || value == "." {
            value = ""
        } else if value.hasPrefix("~/") {
            value.removeFirst(2)
        }

        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\\"),
              !FileUploadPolicy.containsUnsafeCharacters(value) else {
            throw FileUploadError.invalidRemoteDirectory
        }

        if value.isEmpty {
            components = []
            return
        }

        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.count <= FileUploadPolicy.maximumDirectoryComponentBytes
        }) else {
            throw FileUploadError.invalidRemoteDirectory
        }
        components = parts
    }

    var displayPath: String {
        components.isEmpty ? "~" : "~/" + components.joined(separator: "/")
    }
}

struct StagedUploadFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let localURL: URL
    let originalFilename: String
    let byteCount: UInt64
    let kind: FileUploadKind

    var remoteFilename: String {
        (try? FileUploadPolicy.uniqueFilename(originalFilename, id: id)) ?? id.uuidString.lowercased()
    }
}

struct FileUploadProgress: Equatable, Sendable {
    let transferredBytes: UInt64
    let totalBytes: UInt64

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }
}

struct UploadedRemoteFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let remotePath: String
    let originalFilename: String
    let byteCount: UInt64
    let kind: FileUploadKind

    var shellQuotedPath: String {
        (try? FileUploadPolicy.shellQuote(remotePath)) ?? ""
    }
}

/// Copies explicitly selected files into a private, bounded staging area; no provider URLs are retained.
actor FileUploadStagingArea {
    static let shared = FileUploadStagingArea()

    private let rootURL: URL
    private let manager: FileManager

    init(rootURL: URL? = nil, manager: FileManager = .default) {
        self.rootURL = rootURL ?? manager.temporaryDirectory.appendingPathComponent(
            "app.gethoshi.private-uploads",
            isDirectory: true
        )
        self.manager = manager
    }

    func stage(_ source: URL, kind: FileUploadKind) throws -> StagedUploadFile {
        try Task.checkCancellation()
        guard source.isFileURL else { throw FileUploadError.invalidSource }

        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .nameKey,
        ])
        guard values.isSymbolicLink != true else { throw FileUploadError.symbolicLink }
        guard values.isRegularFile == true, values.isDirectory != true else {
            throw FileUploadError.invalidSource
        }

        let filename = try FileUploadPolicy.sanitizeFilename(values.name ?? source.lastPathComponent)
        let initialSize = try fileSize(at: source, suggested: values.fileSize)
        guard initialSize <= FileUploadPolicy.maximumFileBytes else {
            throw FileUploadError.fileTooLarge(maximumBytes: FileUploadPolicy.maximumFileBytes)
        }

        let id = UUID()
        let folder = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(filename, isDirectory: false)

        try manager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            try Task.checkCancellation()
            try manager.copyItem(at: source, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let copiedSize = try fileSize(at: destination, suggested: nil)
            guard copiedSize <= FileUploadPolicy.maximumFileBytes else {
                throw FileUploadError.fileTooLarge(maximumBytes: FileUploadPolicy.maximumFileBytes)
            }
            try Task.checkCancellation()
            return StagedUploadFile(
                id: id,
                localURL: destination,
                originalFilename: filename,
                byteCount: copiedSize,
                kind: kind
            )
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    func remove(_ file: StagedUploadFile) {
        let folder = file.localURL.deletingLastPathComponent().standardizedFileURL
        let root = rootURL.standardizedFileURL
        guard folder.deletingLastPathComponent() == root else { return }
        try? manager.removeItem(at: folder)
    }

    func contains(_ file: StagedUploadFile) -> Bool {
        manager.fileExists(atPath: file.localURL.path)
    }

    private func fileSize(at url: URL, suggested: Int?) throws -> UInt64 {
        if let suggested, suggested >= 0 {
            return UInt64(suggested)
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard let value = attributes[.size] as? NSNumber else {
            throw FileUploadError.invalidSource
        }
        return value.uint64Value
    }
}

/// PhotosPicker supplies file access only within the import closure, so bytes are copied immediately.
struct ImportedUploadImage: Transferable {
    let stagedFile: StagedUploadFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let file = try await FileUploadStagingArea.shared.stage(received.file, kind: .image)
            return ImportedUploadImage(stagedFile: file)
        }
    }
}

actor LocalUploadFileReader {
    private var handle: FileHandle?

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func readChunk(maximumBytes: Int) throws -> Data? {
        guard let handle else { return nil }
        return try handle.read(upToCount: maximumBytes)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

@MainActor
protocol RemoteFileUploading: AnyObject {
    func upload(
        _ file: StagedUploadFile,
        to directory: RemoteUploadDirectory,
        progress: @escaping @Sendable (FileUploadProgress) -> Void
    ) async throws -> UploadedRemoteFile
}

/// Opens SFTP over the current pinned SSH client or a freshly verified Mosh companion connection.
@MainActor
final class SFTPFileUploadBackend: RemoteFileUploading {
    private weak var connection: ConnectionViewModel?

    init(connection: ConnectionViewModel) {
        self.connection = connection
    }

    func upload(
        _ file: StagedUploadFile,
        to directory: RemoteUploadDirectory,
        progress: @escaping @Sendable (FileUploadProgress) -> Void
    ) async throws -> UploadedRemoteFile {
        guard let connection else { throw FileUploadError.disconnected }

        return try await connection.withVerifiedFileTransferClient { client in
            try await client.withSFTP { sftp in
                try await SFTPFileUploadBackend.transfer(
                    file,
                    to: directory,
                    using: sftp,
                    progress: progress
                )
            }
        }
    }

    nonisolated private static func transfer(
        _ file: StagedUploadFile,
        to directory: RemoteUploadDirectory,
        using sftp: SFTPClient,
        progress: @escaping @Sendable (FileUploadProgress) -> Void
    ) async throws -> UploadedRemoteFile {
        try Task.checkCancellation()
        let home = try await sftp.getRealPath(atPath: ".")
        let homeComponents = home.split(separator: "/", omittingEmptySubsequences: false)
        guard home.hasPrefix("/"), !FileUploadPolicy.containsUnsafeCharacters(home),
              home == "/" || !homeComponents.dropFirst().contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              }) else {
            throw FileUploadError.invalidRemotePath
        }

        var current = home
        for component in directory.components {
            try Task.checkCancellation()
            let expected = appending(component, to: current)
            let resolved: String

            do {
                resolved = try await sftp.getRealPath(atPath: expected)
            } catch {
                var permissions = SFTPFileAttributes()
                permissions.permissions = 0o700
                try await sftp.createDirectory(atPath: expected, attributes: permissions)
                resolved = try await sftp.getRealPath(atPath: expected)
            }

            guard resolved == expected, isWithinHome(resolved, home: home) else {
                throw FileUploadError.unsafeRemoteDirectory
            }
            current = resolved
        }

        let filename = try FileUploadPolicy.uniqueFilename(file.originalFilename, id: file.id)
        let finalPath = appending(filename, to: current)
        let partialPath = finalPath + ".part"
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o600

        let remote = try await sftp.openFile(
            filePath: partialPath,
            flags: [.write, .create, .forceCreate],
            attributes: attributes
        )
        var remoteIsOpen = true
        let reader: LocalUploadFileReader

        do {
            reader = try LocalUploadFileReader(url: file.localURL)
        } catch {
            try? await remote.close()
            try? await sftp.remove(at: partialPath)
            throw error
        }

        do {
            var offset: UInt64 = 0
            progress(FileUploadProgress(transferredBytes: 0, totalBytes: file.byteCount))

            while let chunk = try await reader.readChunk(maximumBytes: FileUploadPolicy.chunkBytes),
                  !chunk.isEmpty {
                try Task.checkCancellation()
                var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await remote.write(buffer, at: offset)
                offset += UInt64(chunk.count)
                progress(FileUploadProgress(transferredBytes: offset, totalBytes: file.byteCount))
            }

            await reader.close()
            try Task.checkCancellation()
            try await remote.close()
            remoteIsOpen = false
            try Task.checkCancellation()
            try await sftp.rename(at: partialPath, to: finalPath)
            progress(FileUploadProgress(transferredBytes: file.byteCount, totalBytes: file.byteCount))

            return UploadedRemoteFile(
                id: file.id,
                remotePath: finalPath,
                originalFilename: file.originalFilename,
                byteCount: file.byteCount,
                kind: file.kind
            )
        } catch {
            await reader.close()
            if remoteIsOpen {
                try? await remote.close()
            }
            try? await sftp.remove(at: partialPath)
            throw error
        }
    }

    nonisolated static func appending(_ component: String, to path: String) -> String {
        path == "/" ? "/" + component : path + "/" + component
    }

    nonisolated static func isWithinHome(_ path: String, home: String) -> Bool {
        home == "/" ? path.hasPrefix("/") : path == home || path.hasPrefix(home + "/")
    }
}

enum FileUploadState: Equatable, Sendable {
    case idle
    case importing
    case ready
    case uploading
    case completed
    case cancelled
    case failed
}

@MainActor @Observable
final class FileUploadSettings {
    static let shared = FileUploadSettings()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let directory = "app.gethoshi.uploads.remote-directory"
        static let insertAutomatically = "app.gethoshi.uploads.insert-path-automatically"
    }

    var remoteDirectory: String {
        didSet { defaults.set(remoteDirectory, forKey: Key.directory) }
    }

    var insertPathAutomatically: Bool {
        didSet { defaults.set(insertPathAutomatically, forKey: Key.insertAutomatically) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        remoteDirectory = defaults.string(forKey: Key.directory) ?? ".hoshi/uploads"
        insertPathAutomatically = defaults.object(forKey: Key.insertAutomatically) as? Bool ?? true
    }
}

/// Main-actor upload UI state; SFTP, NIO, and local file reads remain asynchronous.
@MainActor @Observable
final class FileUploadController {
    @ObservationIgnored private let backend: any RemoteFileUploading
    @ObservationIgnored private let staging: FileUploadStagingArea
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?

    private(set) var state: FileUploadState = .idle
    private(set) var selectedFile: StagedUploadFile?
    private(set) var completedFile: UploadedRemoteFile?
    private(set) var progress: FileUploadProgress?
    private(set) var errorMessage: String?
    private(set) var presentedError: ErrorPresentation?
    private(set) var pathWasInserted = false

    init(backend: any RemoteFileUploading, staging: FileUploadStagingArea = .shared) {
        self.backend = backend
        self.staging = staging
    }

    var isUploading: Bool { state == .uploading }

    func importDocument(_ url: URL) async {
        guard !isUploading else { return }

        let acquiredSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if acquiredSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        state = .importing
        errorMessage = nil
        presentedError = nil
        do {
            let file = try await staging.stage(url, kind: .document)
            guard !Task.isCancelled else {
                await staging.remove(file)
                return
            }
            await accept(file)
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    func accept(_ file: StagedUploadFile) async {
        if let previous = selectedFile, previous.id != file.id {
            await staging.remove(previous)
        }
        selectedFile = file
        completedFile = nil
        progress = nil
        errorMessage = nil
        presentedError = nil
        pathWasInserted = false
        state = .ready
    }

    func reportImportFailure(_ error: any Error) {
        fail(error)
    }

    func startUpload(remoteDirectory rawDirectory: String) {
        guard !isUploading else { return }
        guard let selectedFile else {
            fail(FileUploadError.noSelectedFile)
            return
        }

        let directory: RemoteUploadDirectory
        do {
            directory = try RemoteUploadDirectory(rawDirectory)
        } catch {
            fail(error)
            return
        }

        let token = UUID()
        generation = token
        state = .uploading
        errorMessage = nil
        presentedError = nil
        pathWasInserted = false
        progress = FileUploadProgress(transferredBytes: 0, totalBytes: selectedFile.byteCount)

        uploadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await self.backend.upload(selectedFile, to: directory) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.state == .uploading else { return }
                        self.progress = update
                    }
                }
                guard !Task.isCancelled, self.generation == token else {
                    await self.staging.remove(selectedFile)
                    return
                }

                self.completedFile = result
                self.progress = FileUploadProgress(
                    transferredBytes: result.byteCount,
                    totalBytes: result.byteCount
                )
                self.state = .completed
                self.uploadTask = nil
                await self.staging.remove(selectedFile)
            } catch is CancellationError {
                guard self.generation == token else { return }
                self.state = .cancelled
                self.uploadTask = nil
                await self.staging.remove(selectedFile)
            } catch {
                guard self.generation == token else { return }
                self.fail(error)
                self.uploadTask = nil
                self.selectedFile = nil
                await self.staging.remove(selectedFile)
            }
        }
    }

    func cancel() {
        let previous = selectedFile
        generation = nil
        uploadTask?.cancel()
        uploadTask = nil
        selectedFile = nil
        completedFile = nil
        state = .cancelled
        progress = nil
        errorMessage = nil
        presentedError = nil
        pathWasInserted = false
        if let previous {
            Task { await staging.remove(previous) }
        }
    }

    func reset() {
        let previous = selectedFile
        generation = nil
        uploadTask?.cancel()
        uploadTask = nil
        selectedFile = nil
        completedFile = nil
        progress = nil
        errorMessage = nil
        presentedError = nil
        pathWasInserted = false
        state = .idle
        if let previous {
            Task { await staging.remove(previous) }
        }
    }

    func markPathInserted() {
        guard completedFile != nil else { return }
        pathWasInserted = true
    }

    private func fail(_ error: any Error) {
        let presentation = ErrorPresentation.classify(error, context: ErrorContext(operation: .upload))
        presentedError = presentation
        errorMessage = presentation.explanation
        state = .failed
    }
}

@MainActor
final class FileUploadPrivacyCoordinator {
    static let shared = FileUploadPrivacyCoordinator()

    private weak var activeController: FileUploadController?

    func activate(_ controller: FileUploadController) {
        if activeController !== controller {
            activeController?.reset()
        }
        activeController = controller
    }

    func deactivate(_ controller: FileUploadController) {
        guard activeController === controller else { return }
        activeController = nil
        controller.reset()
    }

    func protectSensitiveContent() {
        activeController?.reset()
    }
}
