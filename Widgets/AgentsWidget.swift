import SwiftUI
import WidgetKit

/// The Home Screen and Lock Screen widget: who needs you and who's working, from irex-push's /summary.
/// A widget can't hold the app's socket, so it asks irex-push, and keeps the last answer for when it can't.
struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "agents", provider: AgentsProvider()) { entry in
            AgentsWidgetView(entry: entry)
                .containerBackground(activityNavy, for: .widget)
                .widgetURL(paneURL(entry.state?.items.first?.block) ?? URL(string: "irex://"))
        }
        .configurationDisplayName("Agents")
        .description("Who needs you, and who's working, across your Rex hosts.")
        // ponytail: no large size; irex-push sends three agents, which medium nearly shows already.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct AgentsProvider: TimelineProvider {
    static let sample = AgentsAttributes.ContentState(working: 2, blocked: 1, done: 1, items: [
        .init(title: "builder", state: "blocked", detail: "Run the tests?", block: ""),
        .init(title: "REVIEWER", state: "working", detail: "Reading the diff", block: ""),
        .init(title: "docs", state: "done", detail: "", block: ""),
    ])

    func placeholder(in context: Context) -> AgentsEntry { AgentsEntry(date: .now, state: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(await Self.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        // irex asks for a reload whenever its own count changes; this is for when it's closed.
        Task { completion(Timeline(entries: [await Self.fetch()], policy: .after(.now.addingTimeInterval(15 * 60)))) }
    }

    static func fetch() async -> AgentsEntry {
        let shared = UserDefaults.standard
        guard let address = Bundle.main.object(forInfoDictionaryKey: "IrexRelay") as? String, !address.isEmpty,
              let relay = URL(string: address) else { return AgentsEntry(date: .now, state: nil) }
        var req = URLRequest(url: relay.appending(path: "summary"))
        req.timeoutInterval = 8
        if let (data, response) = try? await URLSession.shared.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200,
           let state = try? JSONDecoder().decode(AgentsAttributes.ContentState.self, from: data) {
            shared.set(data, forKey: "summary")
            return AgentsEntry(date: .now, state: state)
        }
        let cached = shared.data(forKey: "summary").flatMap { try? JSONDecoder().decode(AgentsAttributes.ContentState.self, from: $0) }
        return AgentsEntry(date: .now, state: cached, stale: true)
    }
}
