import SwiftUI

// Shows detected tmux sessions and lets the user attach, create new, or skip
struct TmuxSessionPickerView: View {
    let sessions: [TmuxSessionInfo]
    var onRefresh: (() -> Void)?
    let onChoice: (TmuxChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredSessions: [TmuxSessionInfo] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
                        onChoice(.newSession)
                        dismiss()
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
                                        Text("\(session.windows) window\(session.windows == 1 ? "" : "s")")
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
                        }
                    }
                }
            }
            .navigationTitle("tmux")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Find tmux sessions")
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
