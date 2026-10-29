import AppIntents
import SwiftUI
import WidgetKit

struct ProbeConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "GraphEvo laboratory"
    static let description = IntentDescription("Read the app's laboratory counter from its shared Graph store.")
}

struct ProbeEntry: TimelineEntry {
    let date: Date
    let evidence: WidgetProbeEvidence?
}

struct ProbeTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: .now, evidence: nil) }
    func snapshot(for configuration: ProbeConfiguration, in context: Context) async -> ProbeEntry {
        if context.isPreview { return placeholder(in: context) }
        let evidence = await WidgetProbeReader.load(); return ProbeEntry(date: evidence.date, evidence: evidence)
    }
    func timeline(for configuration: ProbeConfiguration, in context: Context) async -> Timeline<ProbeEntry> {
        let evidence = await WidgetProbeReader.load()
        return Timeline(entries: [ProbeEntry(date: evidence.date, evidence: evidence)], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

struct ProbeWidgetView: View {
    let entry: ProbeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("GraphEvo 2", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            if let evidence = entry.evidence {
                if let value = evidence.value {
                    Text(value, format: .number).font(.system(size: 42, weight: .bold, design: .rounded)).widgetAccentable()
                }
                Text(evidence.status == "ready" ? "Local read-only reader" : evidence.status).font(.caption).lineLimit(2)
                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                if evidence.status == "ready" {
                    Label(evidence.mirrorRefused && evidence.mutationRefused ? "Safeguards passed" : "Check safeguards",
                          systemImage: evidence.mirrorRefused && evidence.mutationRefused ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.caption2)
                }
            } else {
                Text("Add the widget, then prepare a fixture in the app.").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct GraphEvoReadOnlyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetProbeStorage.kind, intent: ProbeConfiguration.self,
                               provider: ProbeTimelineProvider()) { ProbeWidgetView(entry: $0) }
            .configurationDisplayName("GraphEvo laboratory")
            .description("Reads the app's shared Graph store without starting CloudKit.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main struct GraphEvoProbeWidgets: WidgetBundle {
    var body: some Widget { GraphEvoReadOnlyWidget() }
}
