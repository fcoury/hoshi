import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Reviews a user-selected document or photo before a private SSH/SFTP upload.
struct FileUploadView: View {
    let onInsert: (Data) async -> Bool
    private let onUploadCompleted: ((UploadedRemoteFile) -> Void)?
    private let savesDefaultDestination: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var controller: FileUploadController
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showDocumentPicker = false
    @State private var remoteDirectory: String
    @State private var insertionInProgress = false
    @State private var selectionTask: Task<Void, Never>?

    private let settings = FileUploadSettings.shared
    private let appLock = AppLockService.shared

    init(
        connection: ConnectionViewModel,
        controller: FileUploadController? = nil,
        initialRemoteDirectory: String? = nil,
        onUploadCompleted: ((UploadedRemoteFile) -> Void)? = nil,
        onInsert: @escaping (Data) async -> Bool
    ) {
        _controller = State(initialValue: controller ?? FileUploadController(
            backend: SFTPFileUploadBackend(connection: connection)
        ))
        _remoteDirectory = State(initialValue: initialRemoteDirectory ?? FileUploadSettings.shared.remoteDirectory)
        self.onInsert = onInsert
        self.onUploadCompleted = onUploadCompleted
        self.savesDefaultDestination = initialRemoteDirectory == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                selectionSection

                if let file = controller.selectedFile {
                    selectedFileSection(file)
                    destinationSection(file)
                }

                if controller.progress != nil || controller.completedFile != nil {
                    progressSection
                }

                if let presentation = controller.presentedError {
                    Section {
                        ErrorPresentationView(presentation: presentation)
                    }
                }

                privacySection
            }
            .navigationTitle("Upload to Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(controller.isUploading ? "Cancel Upload" : "Done") {
                        closeUploader()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if controller.completedFile == nil {
                        Button("Upload", action: startUpload)
                            .disabled(controller.selectedFile == nil || controller.isUploading)
                            .accessibilityIdentifier("upload.start")
                    }
                }
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { selection in
                handleDocumentSelection(selection)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(controller.isUploading || insertionInProgress)
        .onAppear {
            FileUploadPrivacyCoordinator.shared.activate(controller)
        }
        .onDisappear {
            selectionTask?.cancel()
            selectionTask = nil
            FileUploadPrivacyCoordinator.shared.deactivate(controller)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .onChange(of: controller.completedFile) { _, file in
            guard let file else { return }
            onUploadCompleted?(file)
            guard settings.insertPathAutomatically else { return }
            insertPath(file)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                closeUploader()
            }
        }
        .onChange(of: appLock.isLocked) { _, locked in
            if locked { closeUploader() }
        }
    }

    private var selectionSection: some View {
        Section {
            Button {
                showDocumentPicker = true
            } label: {
                Label("Choose File", systemImage: "doc.badge.plus")
            }
            .disabled(controller.isUploading)
            .accessibilityIdentifier("upload.choose-file")

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Choose Photo", systemImage: "photo.badge.plus")
            }
            .disabled(controller.isUploading)
            .accessibilityIdentifier("upload.choose-photo")
        } header: {
            Text("File or Image")
        } footer: {
            Text("Select one item up to \(ByteCountFormatter.string(fromByteCount: Int64(FileUploadPolicy.maximumFileBytes), countStyle: .file)). Photos are transferred in their original format.")
        }
    }

    private func selectedFileSection(_ file: StagedUploadFile) -> some View {
        Section("Selected Item") {
            LabeledContent {
                Text(file.originalFilename)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } label: {
                Label(file.kind == .image ? "Image" : "File", systemImage: file.kind.systemImage)
            }

            LabeledContent("Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func destinationSection(_ file: StagedUploadFile) -> some View {
        Section {
            TextField(".hoshi/uploads", text: $remoteDirectory)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(controller.isUploading || controller.completedFile != nil)
                .accessibilityLabel("Remote directory inside your home folder")
                .accessibilityIdentifier("upload.remote-directory")

            LabeledContent("Remote Name") {
                Text(file.remoteFilename)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Toggle("Insert Path After Upload", isOn: Binding(
                get: { settings.insertPathAutomatically },
                set: { settings.insertPathAutomatically = $0 }
            ))
            .disabled(controller.isUploading)
        } header: {
            Text("Destination")
        } footer: {
            Text("Directories stay inside your remote home folder. Existing files are never overwritten, and inserted paths are shell-quoted without pressing Return.")
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        Section {
            if let progress = controller.progress {
                ProgressView(value: progress.fractionCompleted) {
                    Text(progressTitle)
                } currentValueLabel: {
                    Text(progressDescription(progress))
                }
                .accessibilityIdentifier("upload.progress")
            }

            if let file = controller.completedFile {
                LabeledContent("Remote Path") {
                    Text(file.remotePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if controller.pathWasInserted {
                    Label("Path inserted without Return", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        insertPath(file)
                    } label: {
                        Label("Insert Shell-Safe Path", systemImage: "text.insert")
                    }
                    .disabled(insertionInProgress)
                    .accessibilityIdentifier("upload.insert-path")
                }
            }
        } header: {
            Text("Transfer")
        }
    }

    private var privacySection: some View {
        Section("Privacy & Safety") {
            Label("Pinned SSH host-key verification", systemImage: "lock.shield")
            Label("Encrypted SFTP transfer", systemImage: "lock.doc")
            Label("Private temporary staging only", systemImage: "internaldrive.badge.xmark")
            Label("Partial files removed when canceled", systemImage: "trash")
        }
    }

    private var progressTitle: String {
        switch controller.state {
        case .completed: "Upload Complete"
        case .cancelled: "Upload Canceled"
        default: "Uploading Securely"
        }
    }

    private func progressDescription(_ progress: FileUploadProgress) -> String {
        let completed = ByteCountFormatter.string(fromByteCount: Int64(progress.transferredBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
        return "\(completed) of \(total)"
    }

    private func handleDocumentSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let files):
            guard let file = files.first else { return }
            selectionTask?.cancel()
            selectionTask = Task { await controller.importDocument(file) }
        case .failure(let error):
            controller.reportImportFailure(error)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        selectionTask?.cancel()
        selectionTask = Task {
            do {
                guard let photo = try await item.loadTransferable(type: ImportedUploadImage.self) else {
                    throw FileUploadError.invalidSource
                }
                guard !Task.isCancelled else {
                    await FileUploadStagingArea.shared.remove(photo.stagedFile)
                    return
                }
                await controller.accept(photo.stagedFile)
            } catch is CancellationError {
                // FileRepresentation staging checks cancellation and cleans up its private copy.
            } catch {
                controller.reportImportFailure(error)
            }
        }
    }

    private func startUpload() {
        do {
            _ = try RemoteUploadDirectory(remoteDirectory)
            if savesDefaultDestination {
                settings.remoteDirectory = remoteDirectory
            }
            controller.startUpload(remoteDirectory: remoteDirectory)
        } catch {
            controller.reportImportFailure(error)
        }
    }

    private func insertPath(_ file: UploadedRemoteFile) {
        guard !controller.pathWasInserted, !insertionInProgress else { return }
        let quoted = file.shellQuotedPath
        guard !quoted.isEmpty else {
            controller.reportImportFailure(FileUploadError.invalidRemotePath)
            return
        }

        insertionInProgress = true
        Task {
            let inserted = await onInsert(Data(quoted.utf8))
            insertionInProgress = false
            if inserted {
                controller.markPathInserted()
                HapticService.success()
            } else {
                controller.reportImportFailure(FileUploadError.disconnected)
            }
        }
    }

    private func closeUploader() {
        selectionTask?.cancel()
        selectionTask = nil
        controller.reset()
        dismiss()
    }
}

struct FileUploadSettingsView: View {
    @State private var directory: String
    @State private var validationError: String?

    private let settings = FileUploadSettings.shared

    init() {
        _directory = State(initialValue: FileUploadSettings.shared.remoteDirectory)
    }

    var body: some View {
        Form {
            Section {
                TextField(".hoshi/uploads", text: $directory)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: directory) { _, value in
                        validateDirectory(value)
                    }

                Toggle("Insert Uploaded Path Automatically", isOn: Binding(
                    get: { settings.insertPathAutomatically },
                    set: { settings.insertPathAutomatically = $0 }
                ))

                if let validationError {
                    ErrorPresentationView(presentation: ErrorPresentation.classify(
                        ErrorMessageFailure(message: validationError),
                        context: ErrorContext(operation: .upload)
                    ))
                }
            } header: {
                Text("Default Destination")
            } footer: {
                Text("Uploads remain inside your remote home folder. Paths are single-quoted and never execute automatically.")
            }

            Section("Transfer Security") {
                LabeledContent("Maximum Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(FileUploadPolicy.maximumFileBytes), countStyle: .file))
                }
                Label("Host-key verified SSH/SFTP", systemImage: "lock.shield")
                Label("Unique names prevent overwrites", systemImage: "doc.badge.gearshape")
                Label("Staged files are removed after transfer", systemImage: "trash")
            }
        }
        .navigationTitle("File Uploads")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func validateDirectory(_ value: String) {
        do {
            _ = try RemoteUploadDirectory(value)
            settings.remoteDirectory = value
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }
    }
}
