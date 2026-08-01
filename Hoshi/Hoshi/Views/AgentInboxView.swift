import SwiftUI

struct AgentAttentionBadge: View {
    let count: Int
    let kind: AgentEventKind?

    private var color: Color {
        let theme = AppearanceSettings.shared.currentTheme
        return switch kind {
        case .approvalRequested: Color(theme.accentRed)
        case .needsAttention: Color(theme.accentYellow)
        default: Color(theme.accentGreen)
        }
    }

    var body: some View {
        if count > 0 {
            Label {
                Text(count > 99 ? "99+" : "\(count)")
            } icon: {
                Image(systemName: kind?.systemImage ?? "bell.fill")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: .capsule)
            .accessibilityLabel("\(count) unread agent event\(count == 1 ? "" : "s")")
        }
    }
}

struct AgentInboxView: View {
    var onOpen: ((AgentInboxEvent) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var filter: InboxFilter = .all
    @State private var showClearConfirmation = false

    private let eventCenter = AgentEventCenter.shared

    private enum InboxFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case approvals = "Approvals"

        var id: String { rawValue }
    }

    private var filteredEvents: [AgentInboxEvent] {
        switch filter {
        case .all: eventCenter.events
        case .unread: eventCenter.events.filter(\.isUnread)
        case .approvals: eventCenter.events.filter { $0.kind == .approvalRequested }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if eventCenter.events.isEmpty {
                    ContentUnavailableView {
                        Label("No Agent Events", systemImage: "bell.badge")
                    } description: {
                        Text("Completion, attention, and approval requests appear here.")
                    }
                } else {
                    eventList
                }
            }
            .navigationTitle("Agent Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Mark All Read", systemImage: "checkmark.circle") {
                            eventCenter.markAllRead()
                        }
                        .disabled(eventCenter.unreadCount == 0)

                        Button("Clear Inbox", systemImage: "trash", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .disabled(eventCenter.events.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Inbox actions")
                }
            }
            .confirmationDialog("Clear All Agent Events?", isPresented: $showClearConfirmation) {
                Button("Clear Inbox", role: .destructive) { eventCenter.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all stored agent notifications from this device.")
            }
        }
    }

    private var eventList: some View {
        List {
            Picker("Show", selection: $filter) {
                ForEach(InboxFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if filteredEvents.isEmpty {
                ContentUnavailableView {
                    Label("No \(filter.rawValue) Events", systemImage: "tray")
                }
            } else {
                ForEach(filteredEvents) { event in
                    eventRow(event)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                eventCenter.remove(eventID: event.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            if event.isUnread {
                                Button {
                                    eventCenter.markRead(eventID: event.id)
                                } label: {
                                    Label("Read", systemImage: "envelope.open")
                                }
                                .tint(.blue)
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    private func eventRow(_ event: AgentInboxEvent) -> some View {
        Button {
            eventCenter.markRead(eventID: event.id)
            onOpen?(event)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(eventColor(event.kind))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(event.title)
                            .font(.body.weight(event.isUnread ? .semibold : .regular))
                        Spacer()
                        Text(event.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let message = event.message, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    Label(eventLocation(event), systemImage: "server.rack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if event.isUnread {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the related terminal session")
    }

    private func eventLocation(_ event: AgentInboxEvent) -> String {
        if let tmux = event.tmuxSession {
            return "\(event.serverName) · \(tmux)"
        }
        return event.serverName
    }

    private func eventColor(_ kind: AgentEventKind) -> Color {
        switch kind {
        case .completed: .green
        case .needsAttention: .orange
        case .approvalRequested: .red
        }
    }
}
