import SwiftUI

// Shows detected tmux sessions and lets the user attach, create new, or skip
struct TmuxSessionPickerView: View {
    let sessions: [TmuxSessionInfo]
    var onRefresh: (() -> Void)?
    let onChoice: (TmuxChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showCreateSession = false
    @State private var newSessionName = ""

    private var filteredSessions: [TmuxSessionInfo] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Raw-shell access is an explicit action, distinct from cancelling the connection.
                Section {
                    Button {
                        onChoice(.skip)
                        dismiss()
                    } label: {
                        Label("Open Raw Shell", systemImage: "terminal")
                    }
                }

                // Sessions list with "New Session" as first item
                Section("tmux Sessions") {
                    Button {
                        newSessionName = ""
                        showCreateSession = true
                    } label: {
                        Label("New Session", systemImage: "plus.rectangle")
                    }

                    if filteredSessions.isEmpty {
                        Label("No sessions found", systemImage: "text.rectangle.page")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredSessions) { session in
                            Button {
                                onChoice(.attach(session))
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.name)
                                            .font(.headline)
                                        HStack(spacing: 6) {
                                            Text("\(session.windows) window\(session.windows == 1 ? "" : "s")")
                                            if let activity = session.lastActivity {
                                                Text("·")
                                                Text(activity, style: .relative)
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if session.isAttached {
                                        Text("attached")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                            .tint(.primary)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Attaches to this tmux session")
                        }
                    }
                }
            }
            .navigationTitle("tmux")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Find tmux sessions")
            .alert("New tmux Session", isPresented: $showCreateSession) {
                TextField("Session name (optional)", text: $newSessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onChoice(name.isEmpty ? .newSession : .newNamedSession(name))
                    dismiss()
                }
                .disabled(!newSessionName.isEmpty && !TmuxDetectionService.isValidSessionName(newSessionName))
            } message: {
                Text("Leave the name empty to let tmux choose one. Names cannot contain a colon or period.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let onRefresh {
                        Button {
                            onRefresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh tmux sessions")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onChoice(.cancel)
                        dismiss()
                    }
                }
            }
        }
    }
}
