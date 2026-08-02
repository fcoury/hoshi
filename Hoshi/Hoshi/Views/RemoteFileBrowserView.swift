import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Home-directory-only remote browsing with private, disposable downloads.
struct RemoteFileBrowserView: View {
    let serverName: String
    let onInsert: (Data) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var controller: RemoteFileBrowserController
    @State private var searchText = ""
    @State private var showHiddenFiles = false
    @State private var showUploader = false
    @State private var previewURL: URL?

    private let connection: ConnectionViewModel
    private let appLock = AppLockService.shared

    init(
        connection: ConnectionViewModel,
        serverName: String,
        controller: RemoteFileBrowserController? = nil,
        onInsert: @escaping (Data) async -> Bool
    ) {
        self.connection = connection
        self.serverName = serverName
        self.onInsert = onInsert
        _controller = State(initialValue: controller ?? RemoteFileBrowserController(
            backend: SFTPRemoteFileBrowserBackend(connection: connection)
        ))
    }

    private var visibleEntries: [RemoteFileEntry] {
        controller.entries.filter { entry in
            (showHiddenFiles || !entry.isHidden)
                && (searchText.isEmpty || entry.name.localizedStandardContains(searchText))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    breadcrumbs
                } footer: {
                    Label("Pinned SSH host verification · Remote home folder only", systemImage: "lock.shield")
                        .font(.caption)
                }

                if controller.isDownloading || controller.downloadedFile != nil {
                    downloadSection
                }

                if let presentation = controller.presentedError {
                    Section {
                        ErrorPresentationView(presentation: presentation)
                    }
                }

                Section {
                    if controller.isLoading && controller.entries.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading files…")
                                .foregroundStyle(.secondary)
                        }
                    } else if visibleEntries.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No Files" : "No Matching Files",
                            systemImage: searchText.isEmpty ? "folder" : "magnifyingglass"
                        )
                    } else {
                        ForEach(visibleEntries) { entry in
                            fileRow(entry)
                        }
                    }
                } header: {
                    Text(controller.currentDirectory.displayPath)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Server Files")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search this folder")
            .refreshable {
                controller.load()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: closeBrowser)
                        .accessibilityIdentifier("file-browser.done")
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showUploader = true
                        } label: {
                            Label("Upload Here", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("file-browser.upload")

                        Button {
                            controller.load()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("File browser actions")
                    .accessibilityIdentifier("file-browser.actions")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(controller.isDownloading)
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showUploader) {
            FileUploadView(
                connection: connection,
                initialRemoteDirectory: controller.currentDirectory.displayPath,
                onUploadCompleted: { _ in controller.load() },
                onInsert: onInsert
            )
        }
        .task {
            controller.load()
        }
        .onAppear {
            RemoteFileBrowserPrivacyCoordinator.shared.activate(controller)
        }
        .onDisappear {
            previewURL = nil
            RemoteFileBrowserPrivacyCoordinator.shared.deactivate(controller)
        }
        .onChange(of: controller.downloadedFile) { _, file in
            guard let file else {
                previewURL = nil
                return
            }
            previewURL = file.localURL
            HapticService.success()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                closeBrowser()
            }
        }
        .onChange(of: appLock.isLocked) { _, locked in
            if locked {
                closeBrowser()
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Button {
                    controller.navigate(to: [])
                } label: {
                    Label(serverName, systemImage: "house")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remote home folder")

                ForEach(Array(controller.currentDirectory.components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button(component) {
                        controller.navigate(to: controller.currentDirectory.components[...index])
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("file-browser.breadcrumbs")
    }

    @ViewBuilder
    private var downloadSection: some View {
        Section("Download") {
            if let progress = controller.downloadProgress, controller.isDownloading {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction) {
                        Text("Downloading securely")
                    } currentValueLabel: {
                        Text(downloadDescription(progress))
                    }
                } else {
                    ProgressView("Downloading securely")
                }

                Button("Cancel Download", role: .cancel) {
                    controller.cancelDownload()
                }
                .accessibilityIdentifier("file-browser.download.cancel")
            }

            if let file = controller.downloadedFile {
                LabeledContent("File") {
                    Text(file.originalFilename)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Button {
                    previewURL = file.localURL
                } label: {
                    Label("Preview File", systemImage: "eye")
                }
                .accessibilityIdentifier("file-browser.preview")

                ShareLink(item: file.localURL) {
                    Label("Share Downloaded File", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("file-browser.share")

                Button("Remove Private Copy", role: .destructive) {
                    controller.clearDownloadedFile()
                }
            }
        }
    }

    private func fileRow(_ entry: RemoteFileEntry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage(for: entry))
                    .font(.title3)
                    .foregroundStyle(entry.kind == .directory ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let bytes = entry.byteCount, entry.kind == .regularFile {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        }
                        if let modified = entry.modificationDate {
                            Text(modified, format: .dateTime.month().day().hour().minute())
                        }
                        if entry.kind == .symbolicLink {
                            Text("Symlink blocked")
                        } else if entry.kind == .other {
                            Text("Unsupported")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if entry.kind == .directory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!entry.isOpenable || controller.isDownloading)
        .accessibilityLabel("\(entry.name), \(entry.kind.accessibilityDescription)")
        .accessibilityHint(entry.kind == .directory ? "Opens this folder" : "Downloads and previews this file")
        .accessibilityIdentifier("file-browser.entry.\(entry.relativePath)")
    }

    private func systemImage(for entry: RemoteFileEntry) -> String {
        guard entry.kind == .regularFile else { return entry.kind.systemImage }
        guard let ext = entry.name.split(separator: ".").last,
              let type = UTType(filenameExtension: String(ext)) else {
            return entry.kind.systemImage
        }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        return entry.kind.systemImage
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.kind == .directory {
            controller.openDirectory(entry)
        } else {
            controller.download(entry)
        }
    }

    private func downloadDescription(_ progress: RemoteFileDownloadProgress) -> String {
        let completed = ByteCountFormatter.string(fromByteCount: Int64(progress.transferredBytes), countStyle: .file)
        guard let total = progress.totalBytes else { return completed }
        return "\(completed) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
    }

    private func closeBrowser() {
        previewURL = nil
        controller.reset()
        dismiss()
    }
}
