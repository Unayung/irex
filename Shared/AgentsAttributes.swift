import ActivityKit
import Foundation

/// The one Live Activity irex shows: every agent on every host, summed up.
/// irex-push sends ContentState in exactly this shape (push/main.go, contentState).
struct AgentsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct Item: Codable, Hashable {
            var title: String
            var state: String    // blocked, working, or done
            var detail: String   // what the agent says it's doing
            var block: String
        }
        var working: Int
        var blocked: Int
        var done: Int
        var items: [Item]

        /// "1 needs you · 2 working", or "All done".
        var headline: String {
            var parts: [String] = []
            if blocked > 0 { parts.append("\(blocked) need\(blocked == 1 ? "s" : "") you") }
            if working > 0 { parts.append("\(working) working") }
            return parts.isEmpty ? "All done" : parts.joined(separator: " · ")
        }
    }
}

/// Where tapping an agent goes: irex://pane/<block ID>.
func paneURL(_ block: String?) -> URL? {
    guard let block, let encoded = block.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    return URL(string: "irex://pane/\(encoded)")
}
