import WidgetKit
import SwiftUI
import ActivityKit

/// Sperrbildschirm und Dynamic Island: nächste Vorlesung mit Raum und Countdown
struct LectureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureAttributes.self) { ctx in
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill").font(.title2).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.attributes.title).font(.headline).lineLimit(1)
                    Text(ctx.state.room.map { (ctx.state.roomChanged ? "Neuer Raum: " : "Raum ") + $0 } ?? "")
                        .font(.subheadline).foregroundStyle(ctx.state.roomChanged ? Palette.warn : .secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    if ctx.state.start > Date() {
                        Text("beginnt").font(.caption2).foregroundStyle(.secondary)
                        Text(timerInterval: Date()...ctx.state.start, countsDown: true).font(.title3.monospacedDigit().bold()).frame(width: 70)
                    } else {
                        Text("noch").font(.caption2).foregroundStyle(.secondary)
                        Text(timerInterval: Date()...ctx.state.end, countsDown: true).font(.title3.monospacedDigit().bold()).frame(width: 70)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Palette.bg)
            .activitySystemActionForegroundColor(Palette.accent)
            .widgetURL(Shared.link("stundenplan"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label(ctx.state.room ?? "", systemImage: "mappin").font(.caption) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...(ctx.state.start > Date() ? ctx.state.start : ctx.state.end), countsDown: true).monospacedDigit().frame(width: 60)
                }
                DynamicIslandExpandedRegion(.bottom) { Text(ctx.attributes.title).font(.headline).lineLimit(1) }
            } compactLeading: {
                Image(systemName: "graduationcap.fill").foregroundStyle(Palette.accent)
            } compactTrailing: {
                Text(timerInterval: Date()...(ctx.state.start > Date() ? ctx.state.start : ctx.state.end), countsDown: true).monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "graduationcap.fill").foregroundStyle(Palette.accent)
            }
            .widgetURL(Shared.link("stundenplan"))
        }
    }
}
