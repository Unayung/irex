import ActivityKit
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

    /// Turns on notifications for the server at `address`.
    func start(server address: String) {
        guard let ep = RexEndpoint(address), let host = ep.base.host else { return }
        relay = URL(string: "https://\(host):7298")
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

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let block = notification.request.content.userInfo["block"] as? String
        return block != nil && block == showing ? [] : [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let block = response.notification.request.content.userInfo["block"] as? String { pendingBlock = block }
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
