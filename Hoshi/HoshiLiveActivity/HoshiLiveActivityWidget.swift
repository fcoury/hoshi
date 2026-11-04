import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HoshiLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        HoshiAgentLiveActivityWidget()
    }
}

private typealias State = AgentLiveActivityAttributes.ContentState
private typealias Status = AgentLiveActivityAttributes.Status

struct HoshiAgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentLiveActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.deepLink(for: context.state))
        } dynamicIsland: { context in
            let state = context.state
            let tint = Palette.tint(for: state.displayStatus)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusGlyph(status: state.displayStatus, size: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.updatedAt, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.primaryText)
                            .font(.headline)
                            .lineLimit(1)
                            .privacySensitive()
                        if let secondary = state.secondaryText {
                            Text(secondary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .privacySensitive()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        AgentCountsRow(state: state)
                        Spacer(minLength: 4)
                        ActionPill(title: state.actionTitle, tint: tint)
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: Palette.glyph(for: state.displayStatus))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            } compactTrailing: {
                CompactCount(state: state)
            } minimal: {
                Image(systemName: Palette.glyph(for: state.displayStatus))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .widgetURL(context.attributes.deepLink(for: state))
            .keylineTint(tint)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenActivityView: View {
    let state: State

    var body: some View {
        let tint = Palette.tint(for: state.displayStatus)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                StatusGlyph(status: state.displayStatus, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.primaryText)
                        .font(.headline)
                        .lineLimit(1)
                        .privacySensitive()
                    if let secondary = state.secondaryText {
                        Text(secondary)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .privacySensitive()
                    }
                }

                Spacer(minLength: 8)

                Text(state.updatedAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72, alignment: .trailing)
            }

            if state.hasAgentCounts || state.displayStatus.wantsReply {
                HStack(spacing: 8) {
                    AgentCountsRow(state: state)
                    Spacer(minLength: 8)
                    ActionPill(title: state.actionTitle, tint: tint)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Components

/// The status symbol on a softly tinted disc.
private struct StatusGlyph: View {
    let status: Status
    let size: CGFloat

    var body: some View {
        let tint = Palette.tint(for: status)
        Image(systemName: Palette.glyph(for: status))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Working / waiting / done chips, showing only non-zero counts.
private struct AgentCountsRow: View {
    let state: State

    var body: some View {
        HStack(spacing: 6) {
            if state.blockedCount > 0 {
                chip(state.blockedCount, "waiting", "hand.raised.fill", Palette.attention)
            }
            if state.workingCount > 0 {
                chip(state.workingCount, "working", "circle.dotted.circle", Palette.working)
            }
            if state.doneCount > 0 {
                chip(state.doneCount, "done", "checkmark", Palette.done)
            }
            if !state.hasAgentCounts, state.attentionCount > 0 {
                chip(state.attentionCount, "unread", "tray.full.fill", Palette.tint(for: state.displayStatus))
            }
        }
    }

    private func chip(_ count: Int, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}

private struct ActionPill: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint, in: .capsule)
    }
}

/// The compact island's trailing count: waiting agents first, then working
/// agents, then unread events.
private struct CompactCount: View {
    let state: State

    var body: some View {
        if state.blockedCount > 0 {
            count(state.blockedCount, Palette.attention)
        } else if state.workingCount > 0 {
            count(state.workingCount, Palette.working)
        } else if state.attentionCount > 0 {
            count(state.attentionCount, Palette.tint(for: state.displayStatus))
        } else {
            Circle()
                .fill(Palette.tint(for: state.displayStatus))
                .frame(width: 6, height: 6)
        }
    }

    private func count(_ value: Int, _ tint: Color) -> some View {
        Text("\(min(value, 99))")
            .font(.system(size: 14, weight: .bold).monospacedDigit())
            .foregroundStyle(tint)
    }
}

private enum Palette {
    static let background = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let working = Color(red: 0.40, green: 0.72, blue: 1.00)
    static let attention = Color(red: 1.00, green: 0.62, blue: 0.20)
    static let done = Color(red: 0.36, green: 0.86, blue: 0.52)
    static let idle = Color(white: 0.75)

    static func tint(for status: Status) -> Color {
        switch status {
        case .running: working
        case .completed: done
        case .needsAttention, .approvalRequested: attention
        }
    }

    static func glyph(for status: Status) -> String {
        switch status {
        case .running: "sparkles"
        case .completed: "checkmark"
        case .needsAttention: "hand.raised.fill"
        case .approvalRequested: "checkmark.shield.fill"
        }
    }
}
