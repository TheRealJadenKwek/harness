import WidgetKit
import SwiftUI
import ActivityKit

@main
struct HarnessWidgets: WidgetBundle {
    var body: some Widget {
        HarnessLiveActivity()
    }
}

/// Lock-screen card + Dynamic Island for a running turn. Phases:
/// thinking/streaming/tool = working (timer), approval = orange "needs you",
/// done = green check with the reply snippet, error = red.
struct HarnessLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HarnessActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .padding(14)
                .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(threadURL(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    engineIconView(context).font(.title3).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingStatus(context).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        phaseLine(context)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } compactLeading: {
                engineIconView(context)
            } compactTrailing: {
                compactStatus(context)
            } minimal: {
                minimalStatus(context)
            }
            .widgetURL(threadURL(context))
            .keylineTint(context.state.phase == "approval" ? .orange : .green)
        }
    }

    private func threadURL(_ context: ActivityViewContext<HarnessActivityAttributes>) -> URL? {
        URL(string: "harness://thread/\(context.attributes.threadID)")
    }

    @ViewBuilder
    private func engineIconView(_ context: ActivityViewContext<HarnessActivityAttributes>) -> some View {
        Image(systemName: context.attributes.engine == "codex"
              ? "chevron.left.forwardslash.chevron.right" : "sparkles")
            .foregroundStyle(context.state.phase == "approval" ? .orange : .green)
    }

    @ViewBuilder
    private func phaseLine(_ context: ActivityViewContext<HarnessActivityAttributes>) -> some View {
        switch context.state.phase {
        case "approval":
            Text("Waiting for your approval — \(context.state.detail)").foregroundStyle(.orange)
        case "tool":
            Text(context.state.detail.isEmpty ? "Using tools…" : context.state.detail)
        case "thinking":
            Text("Thinking…")
        case "done":
            Text(context.state.detail.isEmpty ? "Finished" : context.state.detail)
        case "error":
            Text(context.state.detail.isEmpty ? "Something went wrong" : context.state.detail)
                .foregroundStyle(.red)
        default:
            Text("Writing…")
        }
    }

    @ViewBuilder
    private func trailingStatus(_ context: ActivityViewContext<HarnessActivityAttributes>) -> some View {
        switch context.state.phase {
        case "approval":
            Image(systemName: "hand.raised.fill").font(.title3).foregroundStyle(.orange)
        case "done":
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        case "error":
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.red)
        default:
            Text(context.attributes.startedAt, style: .timer)
                .font(.caption.monospacedDigit()).frame(width: 44)
        }
    }

    @ViewBuilder
    private func compactStatus(_ context: ActivityViewContext<HarnessActivityAttributes>) -> some View {
        switch context.state.phase {
        case "approval":
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case "done":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "error":
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:
            Text(context.attributes.startedAt, style: .timer)
                .font(.caption2.monospacedDigit()).frame(maxWidth: 44)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func minimalStatus(_ context: ActivityViewContext<HarnessActivityAttributes>) -> some View {
        switch context.state.phase {
        case "approval": Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case "done":     Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "error":    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:         Image(systemName: "ellipsis").foregroundStyle(.green)
        }
    }
}

struct LockScreenActivityView: View {
    let context: ActivityViewContext<HarnessActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: context.attributes.engine == "codex"
                      ? "chevron.left.forwardslash.chevron.right" : "sparkles")
                    .foregroundStyle(accent)
                Text(context.attributes.title)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                switch context.state.phase {
                case "approval":
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                case "done":
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case "error":
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                default:
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(maxWidth: 50)
                }
            }
            statusLine
        }
        .foregroundStyle(.white)
    }

    private var accent: Color {
        context.state.phase == "approval" ? .orange : .green
    }

    @ViewBuilder
    private var statusLine: some View {
        switch context.state.phase {
        case "approval":
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for your approval")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                if !context.state.detail.isEmpty {
                    Text(context.state.detail)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        case "tool":
            Text(context.state.detail.isEmpty ? "Using tools…" : context.state.detail)
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
        case "thinking":
            Text("Thinking…").font(.callout).foregroundStyle(.secondary)
        case "done":
            Text(context.state.detail.isEmpty ? "Finished ✓" : context.state.detail)
                .font(.callout).lineLimit(2)
        case "error":
            Text(context.state.detail.isEmpty ? "Something went wrong" : context.state.detail)
                .font(.callout).foregroundStyle(.red).lineLimit(2)
        default:
            Text("Writing…").font(.callout).foregroundStyle(.secondary)
        }
    }
}
