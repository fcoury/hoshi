import Citadel
import Foundation
import NIOCore

enum RemoteFileBrowserError: LocalizedError, Equatable {
    case disconnected
    case missingCredentials
    case invalidHomeDirectory
    case invalidEntryName(String)
    case unsafeRemotePath
    case symbolicLink(String)
    case unsupportedEntry(String)
    case directoryTooLarge(maximumEntries: Int)
    case fileTooLarge(maximumBytes: UInt64)
    case downloadInProgress
    case localFileUnavailable

    var errorDescription: String? {
        switch self {
        case .disconnected:
            "Reconnect to this server before browsing its files."
        case .missingCredentials:
            "This connection no longer has its verified SSH credentials. Reconnect and try again."
        case .invalidHomeDirectory:
            "The server returned an invalid remote home directory."
        case .invalidEntryName(let name):
            "The server returned an unsafe file or folder name: \(name)."
        case .unsafeRemotePath:
            "This file or folder resolves outside your remote home directory."
        case .symbolicLink(let name):
            "The symbolic link \(name) cannot be opened safely."
        case .unsupportedEntry(let name):
            "\(name) is not a regular file or folder."
        case .directoryTooLarge(let maximumEntries):
            "This folder contains more than \(maximumEntries) entries."
        case .fileTooLarge(let maximumBytes):
            "Downloads are limited to \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))."
        case .downloadInProgress:
            "Wait for the current download to finish, or cancel it first."
        case .localFileUnavailable:
            "Hoshi could not create a private temporary file for this download."
        }
    }
}

enum RemoteFileKind: String, Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other

    var systemImage: String {
        switch self {
        case .directory: "folder"
        case .regularFile: "doc"
        case .symbolicLink: "link"
        case .other: "questionmark.square.dashed"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .directory: "folder"
        case .regularFile: "file"
        case .symbolicLink: "symbolic link"
        case .other: "unsupported item"
        }
    }
}

struct RemoteFileEntry: Identifiable, Equatable, Sendable {
    let name: String
    let directory: RemoteUploadDirectory
    let kind: RemoteFileKind
    let byteCount: UInt64?
    let modificationDate: Date?

    var id: String { relativePath }

    var relativePath: String {
        (directory.components + [name]).joined(separator: "/")
    }

    var displayPath: String { "~/" + relativePath }

    var isHidden: Bool { name.hasPrefix(".") }
    var isOpenable: Bool { kind == .directory || kind == .regularFile }
}

enum RemoteFileBrowserPolicy {
    static let maximumDirectoryEntries = 2_000
    static let maximumDownloadBytes = FileUploadPolicy.maximumFileBytes
    static let downloadChunkBytes = FileUploadPolicy.chunkBytes

    nonisolated static func validateHome(_ home: String) throws -> String {
        let components = home.split(separator: "/", omittingEmptySubsequences: false)
        guard home.hasPrefix("/"),
              !FileUploadPolicy.containsUnsafeCharacters(home),
              home == "/" || !components.dropFirst().contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              }) else {
            throw RemoteFileBrowserError.invalidHomeDirectory
        }
        return home
    }

    nonisolated static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              name.utf8.count <= FileUploadPolicy.maximumFilenameBytes,
              !FileUploadPolicy.containsUnsafeCharacters(name) else {
            throw RemoteFileBrowserError.invalidEntryName(ErrorRedactor.redact(name))
        }
    }

    nonisolated static func classify(permissions: UInt32?, longname: String) -> RemoteFileKind {
        if let permissions {
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o100000: return .regularFile
            case 0o120000: return .symbolicLink
            default: break
            }
        }

        switch longname.first {
        case "d": return .directory
        case "-": return .regularFile
        case "l": return .symbolicLink
        default: return .other
        }
    }

    nonisolated static func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { first, second in
            let firstRank = first.kind == .directory ? 0 : 1
            let secondRank = second.kind == .directory ? 0 : 1
            if firstRank != secondRank { return firstRank < secondRank }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    nonisolated static func childDirectory(
        named name: String,
        in directory: RemoteUploadDirectory
    ) throws -> RemoteUploadDirectory {
        try validateEntryName(name)
        return try RemoteUploadDirectory((directory.components + [name]).joined(separator: "/"))
    }

    nonisolated static func parentDirectory(of directory: RemoteUploadDirectory) throws -> RemoteUploadDirectory? {
        guard !directory.components.isEmpty else { return nil }
        return try RemoteUploadDirectory(directory.components.dropLast().joined(separator: "/"))
    }
}

struct RemoteFileDownloadProgress: Equatable, Sendable {
    let transferredBytes: UInt64
    let totalBytes: UInt64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }
}

struct DownloadedRemoteFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let localURL: URL
    let originalFilename: String
    let byteCount: UInt64
    let remotePath: String
}

struct PendingRemoteFileDownload: Equatable, Sendable {
    let id: UUID
    let finalURL: URL
    let partialURL: URL
    let originalFilename: String
    let remotePath: String
}

actor RemoteFileDownloadStagingArea {
    static let shared = RemoteFileDownloadStagingArea()

    private let rootURL: URL
    private let manager: FileManager

    init(rootURL: URL? = nil, manager: FileManager = .default) {
        self.rootURL = rootURL ?? manager.temporaryDirectory.appendingPathComponent(
            "app.gethoshi.private-downloads",
            isDirectory: true
        )
        self.manager = manager
    }

    func prepare(_ entry: RemoteFileEntry) throws -> PendingRemoteFileDownload {
        try Task.checkCancellation()
        try RemoteFileBrowserPolicy.validateEntryName(entry.name)
        let safeName = try FileUploadPolicy.sanitizeFilename(entry.name)
        guard safeName == entry.name else {
            throw RemoteFileBrowserError.invalidEntryName(entry.name)
        }

        let id = UUID()
        let folder = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
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

        return PendingRemoteFileDownload(
            id: id,
            finalURL: folder.appendingPathComponent(safeName, isDirectory: false),
            partialURL: folder.appendingPathComponent(".partial", isDirectory: false),
            originalFilename: safeName,
            remotePath: entry.displayPath
        )
    }

    func complete(_ pending: PendingRemoteFileDownload, byteCount: UInt64) throws -> DownloadedRemoteFile {
        try Task.checkCancellation()
        guard manager.fileExists(atPath: pending.partialURL.path) else {
            throw RemoteFileBrowserError.localFileUnavailable
        }
        try manager.moveItem(at: pending.partialURL, to: pending.finalURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.finalURL.path)

        return DownloadedRemoteFile(
            id: pending.id,
            localURL: pending.finalURL,
            originalFilename: pending.originalFilename,
            byteCount: byteCount,
            remotePath: pending.remotePath
        )
    }

    func remove(_ pending: PendingRemoteFileDownload) {
        removeFolder(pending.finalURL.deletingLastPathComponent())
    }

    func remove(_ file: DownloadedRemoteFile) {
        removeFolder(file.localURL.deletingLastPathComponent())
    }

    private func removeFolder(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard folder.deletingLastPathComponent() == rootURL.standardizedFileURL else { return }
        try? manager.removeItem(at: folder)
    }
}

private actor LocalDownloadedFileWriter {
    private var handle: FileHandle?

    init(url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw RemoteFileBrowserError.localFileUnavailable
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ bytes: Data) throws {
        guard let handle else { throw RemoteFileBrowserError.localFileUnavailable }
        try handle.write(contentsOf: bytes)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

@MainActor
protocol RemoteFileBrowsing: AnyObject {
    func list(_ directory: RemoteUploadDirectory) async throws -> [RemoteFileEntry]
    func download(
        _ entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (RemoteFileDownloadProgress) -> Void
    ) async throws -> UInt64
}

@MainActor
final class SFTPRemoteFileBrowserBackend: RemoteFileBrowsing {
    private weak var connection: ConnectionViewModel?

    init(connection: ConnectionViewModel) {
        self.connection = connection
    }

    func list(_ directory: RemoteUploadDirectory) async throws -> [RemoteFileEntry] {
        guard let connection else { throw RemoteFileBrowserError.disconnected }
        guard connection.connectionState == .connected else { throw RemoteFileBrowserError.disconnected }

        do {
            return try await connection.withVerifiedFileTransferClient { client in
                try await client.withSFTP { sftp in
                    let home = try RemoteFileBrowserPolicy.validateHome(
                        try await sftp.getRealPath(atPath: ".")
                    )
                    let path = try await Self.resolve(directory, home: home, using: sftp)
                    let groups = try await sftp.listDirectory(atPath: path)
                    let components = groups.flatMap(\.components).filter {
                        $0.filename != "." && $0.filename != ".."
                    }
                    guard components.count <= RemoteFileBrowserPolicy.maximumDirectoryEntries else {
                        throw RemoteFileBrowserError.directoryTooLarge(
                            maximumEntries: RemoteFileBrowserPolicy.maximumDirectoryEntries
                        )
                    }

                    var entries: [RemoteFileEntry] = []
                    for component in components {
                        try Task.checkCancellation()
                        try RemoteFileBrowserPolicy.validateEntryName(component.filename)
                        entries.append(RemoteFileEntry(
                            name: component.filename,
                            directory: directory,
                            kind: RemoteFileBrowserPolicy.classify(
                                permissions: component.attributes.permissions,
                                longname: component.longname
                            ),
                            byteCount: component.attributes.size,
                            modificationDate: component.attributes.accessModificationTime?.modificationTime
                        ))
                    }
                    return RemoteFileBrowserPolicy.sorted(entries)
                }
            }
        } catch let error as FileUploadError {
            throw Self.browserError(for: error)
        }
    }

    func download(
        _ entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (RemoteFileDownloadProgress) -> Void
    ) async throws -> UInt64 {
        guard let connection else { throw RemoteFileBrowserError.disconnected }
        guard connection.connectionState == .connected else { throw RemoteFileBrowserError.disconnected }
        guard entry.kind == .regularFile else {
            if entry.kind == .symbolicLink {
                throw RemoteFileBrowserError.symbolicLink(entry.name)
            }
            throw RemoteFileBrowserError.unsupportedEntry(entry.name)
        }
        if let size = entry.byteCount, size > RemoteFileBrowserPolicy.maximumDownloadBytes {
            throw RemoteFileBrowserError.fileTooLarge(maximumBytes: RemoteFileBrowserPolicy.maximumDownloadBytes)
        }

        do {
            return try await connection.withVerifiedFileTransferClient { client in
                try await client.withSFTP { sftp in
                    try await Self.transfer(entry, to: destination, using: sftp, progress: progress)
                }
            }
        } catch let error as FileUploadError {
            throw Self.browserError(for: error)
        }
    }

    nonisolated private static func browserError(for error: FileUploadError) -> any Error {
        switch error {
        case .disconnected: RemoteFileBrowserError.disconnected
        case .missingCredentials: RemoteFileBrowserError.missingCredentials
        default: error
        }
    }

    nonisolated private static func resolve(
        _ directory: RemoteUploadDirectory,
        home: String,
        using sftp: SFTPClient
    ) async throws -> String {
        var current = home
        for component in directory.components {
            try Task.checkCancellation()
            let expected = SFTPFileUploadBackend.appending(component, to: current)
            let resolved = try await sftp.getRealPath(atPath: expected)
            guard resolved == expected, SFTPFileUploadBackend.isWithinHome(resolved, home: home) else {
                throw RemoteFileBrowserError.unsafeRemotePath
            }
            current = resolved
        }
        return current
    }

    nonisolated private static func transfer(
        _ entry: RemoteFileEntry,
        to destination: URL,
        using sftp: SFTPClient,
        progress: @escaping @Sendable (RemoteFileDownloadProgress) -> Void
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        try RemoteFileBrowserPolicy.validateEntryName(entry.name)
        let home = try RemoteFileBrowserPolicy.validateHome(try await sftp.getRealPath(atPath: "."))
        let directory = try await resolve(entry.directory, home: home, using: sftp)
        let expected = SFTPFileUploadBackend.appending(entry.name, to: directory)
        let resolved = try await sftp.getRealPath(atPath: expected)
        guard resolved == expected, SFTPFileUploadBackend.isWithinHome(resolved, home: home) else {
            throw RemoteFileBrowserError.unsafeRemotePath
        }

        let attributes = try await sftp.getAttributes(at: resolved)
        if let size = attributes.size, size > RemoteFileBrowserPolicy.maximumDownloadBytes {
            throw RemoteFileBrowserError.fileTooLarge(maximumBytes: RemoteFileBrowserPolicy.maximumDownloadBytes)
        }
        if let permissions = attributes.permissions,
           permissions & 0o170000 != 0,
           permissions & 0o170000 != 0o100000 {
            throw RemoteFileBrowserError.unsupportedEntry(entry.name)
        }

        let remote = try await sftp.openFile(filePath: resolved, flags: .read)
        var remoteIsOpen = true
        let writer: LocalDownloadedFileWriter

        do {
            writer = try LocalDownloadedFileWriter(url: destination)
        } catch {
            try? await remote.close()
            throw error
        }

        do {
            var offset: UInt64 = 0
            let expectedSize = attributes.size
            progress(RemoteFileDownloadProgress(transferredBytes: 0, totalBytes: expectedSize))

            while true {
                try Task.checkCancellation()
                var buffer = try await remote.read(
                    from: offset,
                    length: UInt32(RemoteFileBrowserPolicy.downloadChunkBytes)
                )
                let count = buffer.readableBytes
                guard count > 0 else { break }
                guard offset + UInt64(count) <= RemoteFileBrowserPolicy.maximumDownloadBytes else {
                    throw RemoteFileBrowserError.fileTooLarge(
                        maximumBytes: RemoteFileBrowserPolicy.maximumDownloadBytes
                    )
                }
                guard let bytes = buffer.readData(length: count) else {
                    throw RemoteFileBrowserError.localFileUnavailable
                }
                try await writer.write(bytes)
                offset += UInt64(count)
                progress(RemoteFileDownloadProgress(transferredBytes: offset, totalBytes: expectedSize))
            }

            await writer.close()
            try Task.checkCancellation()
            try await remote.close()
            remoteIsOpen = false
            progress(RemoteFileDownloadProgress(transferredBytes: offset, totalBytes: expectedSize ?? offset))
            return offset
        } catch {
            await writer.close()
            if remoteIsOpen {
                try? await remote.close()
            }
            throw error
        }
    }
}

@MainActor @Observable
final class RemoteFileBrowserController {
    @ObservationIgnored private let backend: any RemoteFileBrowsing
    @ObservationIgnored private let staging: RemoteFileDownloadStagingArea
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var listingGeneration: UUID?
    @ObservationIgnored private var downloadGeneration: UUID?
    @ObservationIgnored private var pendingDownload: PendingRemoteFileDownload?

    private(set) var currentDirectory: RemoteUploadDirectory
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var isLoading = false
    private(set) var isDownloading = false
    private(set) var downloadProgress: RemoteFileDownloadProgress?
    private(set) var downloadedFile: DownloadedRemoteFile?
    private(set) var presentedError: ErrorPresentation?

    init(
        backend: any RemoteFileBrowsing,
        staging: RemoteFileDownloadStagingArea = .shared,
        directory: RemoteUploadDirectory? = nil
    ) {
        self.backend = backend
        self.staging = staging
        self.currentDirectory = directory ?? (try! RemoteUploadDirectory("~"))
    }

    var canNavigateUp: Bool { !currentDirectory.components.isEmpty }

    func load(_ directory: RemoteUploadDirectory? = nil) {
        let directory = directory ?? currentDirectory
        listingTask?.cancel()
        let generation = UUID()
        listingGeneration = generation
        isLoading = true
        presentedError = nil

        listingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let entries = try await self.backend.list(directory)
                guard !Task.isCancelled, self.listingGeneration == generation else { return }
                guard entries.count <= RemoteFileBrowserPolicy.maximumDirectoryEntries else {
                    throw RemoteFileBrowserError.directoryTooLarge(
                        maximumEntries: RemoteFileBrowserPolicy.maximumDirectoryEntries
                    )
                }
                self.currentDirectory = directory
                self.entries = RemoteFileBrowserPolicy.sorted(entries)
                self.isLoading = false
                self.listingTask = nil
            } catch is CancellationError {
                guard self.listingGeneration == generation else { return }
                self.isLoading = false
                self.listingTask = nil
            } catch {
                guard self.listingGeneration == generation else { return }
                self.present(error)
                self.isLoading = false
                self.listingTask = nil
            }
        }
    }

    func openDirectory(_ entry: RemoteFileEntry) {
        guard entry.kind == .directory else {
            present(entry.kind == .symbolicLink
                ? RemoteFileBrowserError.symbolicLink(entry.name)
                : RemoteFileBrowserError.unsupportedEntry(entry.name))
            return
        }

        do {
            load(try RemoteFileBrowserPolicy.childDirectory(named: entry.name, in: currentDirectory))
        } catch {
            present(error)
        }
    }

    func navigateUp() {
        do {
            guard let parent = try RemoteFileBrowserPolicy.parentDirectory(of: currentDirectory) else { return }
            load(parent)
        } catch {
            present(error)
        }
    }

    func navigate(to components: ArraySlice<String>) {
        do {
            load(try RemoteUploadDirectory(components.joined(separator: "/")))
        } catch {
            present(error)
        }
    }

    func download(_ entry: RemoteFileEntry) {
        guard !isDownloading else {
            present(RemoteFileBrowserError.downloadInProgress)
            return
        }
        guard entry.kind == .regularFile else {
            present(entry.kind == .symbolicLink
                ? RemoteFileBrowserError.symbolicLink(entry.name)
                : RemoteFileBrowserError.unsupportedEntry(entry.name))
            return
        }
        if let size = entry.byteCount, size > RemoteFileBrowserPolicy.maximumDownloadBytes {
            present(RemoteFileBrowserError.fileTooLarge(maximumBytes: RemoteFileBrowserPolicy.maximumDownloadBytes))
            return
        }

        clearDownloadedFile()
        let generation = UUID()
        downloadGeneration = generation
        isDownloading = true
        presentedError = nil
        downloadProgress = RemoteFileDownloadProgress(transferredBytes: 0, totalBytes: entry.byteCount)

        downloadTask = Task { [weak self] in
            guard let self else { return }
            var pending: PendingRemoteFileDownload?

            do {
                let staged = try await self.staging.prepare(entry)
                pending = staged
                self.pendingDownload = staged

                let count = try await self.backend.download(entry, to: staged.partialURL) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadGeneration == generation, self.isDownloading else { return }
                        self.downloadProgress = update
                    }
                }
                try Task.checkCancellation()
                guard self.downloadGeneration == generation else {
                    await self.staging.remove(staged)
                    return
                }

                let downloaded = try await self.staging.complete(staged, byteCount: count)
                self.downloadedFile = downloaded
                self.downloadProgress = RemoteFileDownloadProgress(transferredBytes: count, totalBytes: count)
                self.pendingDownload = nil
                self.isDownloading = false
                self.downloadTask = nil
            } catch is CancellationError {
                if let pending { await self.staging.remove(pending) }
                guard self.downloadGeneration == generation else { return }
                self.pendingDownload = nil
                self.downloadProgress = nil
                self.isDownloading = false
                self.downloadTask = nil
            } catch {
                if let pending { await self.staging.remove(pending) }
                guard self.downloadGeneration == generation else { return }
                self.pendingDownload = nil
                self.downloadProgress = nil
                self.isDownloading = false
                self.downloadTask = nil
                self.present(error)
            }
        }
    }

    func cancelDownload() {
        let pending = pendingDownload
        downloadGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        pendingDownload = nil
        downloadProgress = nil
        isDownloading = false
        if let pending {
            Task { await staging.remove(pending) }
        }
    }

    func clearDownloadedFile() {
        guard let downloadedFile else { return }
        self.downloadedFile = nil
        Task { await staging.remove(downloadedFile) }
    }

    func reset() {
        listingGeneration = nil
        listingTask?.cancel()
        listingTask = nil
        isLoading = false
        entries = []
        presentedError = nil
        cancelDownload()
        clearDownloadedFile()
    }

    private func present(_ error: any Error) {
        guard ErrorPresentation.shouldPresent(error) else { return }
        presentedError = ErrorPresentation.classify(error, context: ErrorContext(operation: .fileBrowser))
    }
}

@MainActor
final class RemoteFileBrowserPrivacyCoordinator {
    static let shared = RemoteFileBrowserPrivacyCoordinator()

    private weak var activeController: RemoteFileBrowserController?

    func activate(_ controller: RemoteFileBrowserController) {
        if activeController !== controller {
            activeController?.reset()
        }
        activeController = controller
    }

    func deactivate(_ controller: RemoteFileBrowserController) {
        guard activeController === controller else { return }
        activeController = nil
        controller.reset()
    }

    func protectSensitiveContent() {
        activeController?.reset()
    }
}
