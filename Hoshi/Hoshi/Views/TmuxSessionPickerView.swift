import SwiftUI

// Shows detected tmux sessions and lets the user attach, create new, or skip
struct TmuxSessionPickerView: View {
    let sessions: [TmuxSessionInfo]
    let onChoice: (TmuxChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Quick escape at the top
                Section {
                    Button {
                        onChoice(.skip)
                        dismiss()
                    } label: {
                        Label("Skip", systemImage: "arrow.right.circle")
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

                    if sessions.isEmpty {
                        Label("No sessions found", systemImage: "text.rectangle.page")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { session in
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onChoice(.skip)
                        dismiss()
                    }
                }
            }
        }
    }
}
