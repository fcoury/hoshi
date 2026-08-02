import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HoshiLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        HoshiAgentLiveActivityWidget()
    }
}

struct HoshiAgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentLiveActivityAttributes.self) { context in
            AgentLockScreenActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.12, green: 0.13, blue: 0.16))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.deepLink(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Hoshi", systemImage: "terminal")
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.status.systemImage)
                            .foregroundStyle(activityTint(for: context.state.status))
                        Text(context.state.status.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(context.state.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.status.systemImage)
                    .foregroundStyle(activityTint(for: context.state.status))
            } compactTrailing: {
                if context.state.attentionCount > 0 {
                    Text("\(context.state.attentionCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(activityTint(for: context.state.status))
                } else {
                    Image(systemName: "terminal")
                        .font(.caption)
                }
            } minimal: {
                Image(systemName: context.state.status.systemImage)
                    .foregroundStyle(activityTint(for: context.state.status))
            }
            .widgetURL(context.attributes.deepLink(for: context.state))
            .keylineTint(activityTint(for: context.state.status))
        }
    }
}

private struct AgentLockScreenActivityView: View {
    let context: ActivityViewContext<AgentLiveActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: context.state.status.systemImage)
                .font(.title2)
                .foregroundStyle(activityTint(for: context.state.status))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .privacySensitive()

                Text(context.state.status.title)
                    .font(.subheadline)
                    .foregroundStyle(activityTint(for: context.state.status))

                if let session = context.state.tmuxSession {
                    Label(session, systemImage: "rectangle.split.3x1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if context.state.attentionCount > 0 {
                    Text("\(context.state.attentionCount) unread")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(activityTint(for: context.state.status))
                }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private func activityTint(for status: AgentLiveActivityAttributes.Status) -> Color {
    switch status {
    case .running: .cyan
    case .completed: .green
    case .needsAttention: .yellow
    case .approvalRequested: .orange
    }
}
