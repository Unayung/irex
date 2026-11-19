import ActivityKit
import SwiftUI
import UIKit
import UserNotifications

/// Notifications and the Live Activity come from irex-push on the server's machine
/// (push/ in this repo). irex hands it the push tokens: the device's, the one that starts
/// the Live Activity, and the running activity's. irex-push listens on port 7298 of the
/// server's host.
@MainActor
final class Push: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Push()

    @Published var state = "Off"
    /// A pane a notification or the Live Activity asked for, until the list can open it.
    @Published var pendingBlock: String?
    /// The pane on screen, so its own notifications don't pop up over it.
    var showing: String?
    /// Sessions and panes irex-push keeps quiet: no notifications, not in the Live Activity.
    @Published private(set) var muted: Set<String> = []

    private var relay: URL?
    private var deviceToken: String?
    private var startToken: String?
    private var activityToken: String?
    private var watching = false

    #if DEBUG
    private let env = "sandbox"       // development builds get development push tokens
    #else
    private let env = "production"
    #endif

    /// irex-push runs beside the server, on port 7298.
    @discardableResult
    func useRelay(server address: String) -> Bool {
        guard let ep = RexEndpoint(address), let host = ep.base.host else { return false }
        relay = URL(string: "https://\(host):7298")
        return true
    }

    /// Turns on notifications for the server at `address`.
    func start(server address: String) {
        guard useRelay(server: address) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            state = allowed ? "Waiting for the device token…" : "Not allowed. Turn them on in iOS Settings."
            if allowed { UIApplication.shared.registerForRemoteNotifications() }
        }
        loadMutes()
        guard !watching else { send(); return }
        watching = true
        if #available(iOS 17.2, *) {
            Task { for await data in Activity<AgentsAttributes>.pushToStartTokenUpdates { startToken = data.hex; send() } }
        }
        Task { for await activity in Activity<AgentsAttributes>.activityUpdates { watch(activity) } }
    }

    private func watch(_ activity: Activity<AgentsAttributes>) {
        // One card is enough: a newer activity replaces any older ones.
        for other in Activity<AgentsAttributes>.activities where other.id != activity.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        Task { for await data in activity.pushTokenUpdates { activityToken = data.hex; send() } }
    }

    func gotDeviceToken(_ data: Data) {
        deviceToken = data.hex
        send()
    }

    func failed(_ error: Error) { state = "No push token: \(error.localizedDescription)" }

    private func send() {
        guard let relay, let deviceToken else { return }
        var body: [String: Any] = ["token": deviceToken, "env": env]
        if let startToken { body["start_token"] = startToken }
        if let activityToken { body["activity_token"] = activityToken }
        var req = URLRequest(url: relay.appending(path: "register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                state = code == 204 ? "On" : "irex-push answered \(code)"
            } catch {
                state = "Can't reach irex-push on \(relay.host ?? "the server")"
            }
        }
    }

    func loadMutes() {
        guard let relay else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: relay.appending(path: "mutes")),
                  let r = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
            muted = Set(r["muted"] ?? [])
        }
    }

    /// Mutes or unmutes a session or pane ID, for every device, since irex-push sends for all of them.
    func setMuted(_ id: String, _ on: Bool) {
        guard let relay else { return }
        if on { muted.insert(id) } else { muted.remove(id) }   // show it now; the answer confirms it
        var req = URLRequest(url: relay.appending(path: "mutes"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "muted": on])
        Task {
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let r = try? JSONDecoder().decode([String: [String]].self, from: data) {
                muted = Set(r["muted"] ?? [])
            } else {
                loadMutes()
            }
        }
    }

    /// Asks irex-push to send this device a notification.
    func test() {
        guard let relay else { return }
        var req = URLRequest(url: relay.appending(path: "test"))
        req.httpMethod = "POST"
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    #if DEBUG
    /// The sample agents for a scenario: busy (one needs you), working, or done.
    static func demoState(_ kind: String) -> AgentsAttributes.ContentState {
        typealias Item = AgentsAttributes.ContentState.Item
        let reviewer = Item(title: "REVIEWER", state: "blocked", detail: "Allow Bash(gh pr merge 4901)?", block: "block:demo-1")
        let builder = Item(title: "Pluto prod agent API key", state: "working", detail: "Running the migration tests", block: "block:demo-2")
        let parser = Item(title: "Parser refactor", state: "working", detail: "Reading src/config/loader.ts", block: "block:demo-3")
        let done = Item(title: "Slow responses report", state: "done", detail: "Posted PR #258", block: "block:demo-4")
        switch kind {
        case "working": return .init(working: 2, blocked: 0, done: 1, items: [builder, parser, done])
        case "done": return .init(working: 0, blocked: 0, done: 2, items: [done, Item(title: "Golden sample Q4", state: "done", detail: "Wrote the Notion page", block: "block:demo-5")])
        default: return .init(working: 3, blocked: 1, done: 1, items: [reviewer, builder, parser])   // two more than shown
        }
    }

    /// `-renderActivity YES` draws the Live Activity's views for each scenario into Documents/activity-*.png:
    /// the lock screen, the expanded Dynamic Island, and the compact one (screenshots can't show the island).
    func renderActivity() {
        for kind in ["busy", "working", "done"] {
            let state = Self.demoState(kind)
            let sheet = VStack(spacing: 18) {
                LockScreen(state: state)
                    .frame(width: 370)
                    .background(activityNavy, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Mark().padding(.leading, 6); Spacer(); ExpandedHeadline(state: state) }
                    Rows(items: state.items, more: state.more).padding(.horizontal, 6)
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
                .frame(width: 370)
                .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
                HStack {
                    Mark()
                    Spacer()
                    CompactCount(state: state)
                }
                .padding(.horizontal, 16)
                .frame(width: 250, height: 37)
                .background(.black, in: Capsule())
                .overlay { Capsule().fill(Color(white: 0.12)).frame(width: 125, height: 37) }   // where the camera sits
            }
            .padding(24)
            .background(Color(white: 0.35))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 3
            if let png = renderer.uiImage?.pngData() {
                try? png.write(to: URL.documentsDirectory.appending(path: "activity-\(kind).png"))
            }
        }
    }

    /// `-demoActivity busy|working|done` starts a Live Activity with sample agents, to look at it in the simulator.
    func demoActivity(_ kind: String) {
        let state = Self.demoState(kind)
        for a in Activity<AgentsAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        do {
            let a = try Activity.request(attributes: AgentsAttributes(), content: .init(state: state, staleDate: nil))
            let note = "started \(a.id) enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled) count=\(Activity<AgentsAttributes>.activities.count)"
            try? note.write(to: URL.documentsDirectory.appending(path: "demo.txt"), atomically: true, encoding: .utf8)
        } catch {
            let note = "failed \(error) enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)"
            try? note.write(to: URL.documentsDirectory.appending(path: "demo.txt"), atomically: true, encoding: .utf8)
        }
    }
    #endif

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let block = notification.request.content.userInfo["block"] as? String
        return block != nil && block == showing ? [] : [.banner, .sound, .list]
    }

    /// The answers a "Needs you" notification offers, as Claude Code numbers them. They type into a
    /// terminal, so a locked phone asks for Face ID first.
    static func registerActions() {
        let answers = [("1", "1 · Yes"), ("2", "2 · Yes, don't ask again"), ("3", "3 · No")].map { key, title in
            UNNotificationAction(identifier: "reply.\(key)", title: title, options: [.authenticationRequired])
        }
        let blocked = UNNotificationCategory(identifier: "agent.blocked", actions: answers, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([blocked])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let block = response.notification.request.content.userInfo["block"] as? String else { return }
        if response.actionIdentifier.hasPrefix("reply.") {
            // Answered from the notification: type it in and stay out of the way.
            let key = String(response.actionIdentifier.dropFirst("reply.".count))
            await AppModel.shared.answer(block, key: key, server: UserDefaults.standard.string(forKey: "server") ?? "")
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            pendingBlock = block
        }
    }

    /// irex://pane/<block ID>, from the Live Activity.
    func open(_ url: URL) {
        guard url.scheme == "irex", url.host == "pane" else { return }
        pendingBlock = url.lastPathComponent.removingPercentEncoding
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes, so tapping a notification that launched irex still lands.
        UNUserNotificationCenter.current().delegate = Push.shared
        Push.registerActions()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Push.shared.gotDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Push.shared.failed(error) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
