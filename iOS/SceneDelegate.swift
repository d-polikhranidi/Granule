import ClickHouseCore
import UIKit

/// A window: the connections, and the one opened (its schema beside its
/// editor and result, in a split view).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let connections = ConnectionsViewController()
        window.rootViewController = UINavigationController(rootViewController: connections)
        window.makeKeyAndVisible()
        self.window = window
        // A window opened for a connection (its menu, dragged out, or restored): connected at once.
        let activity = connectionOptions.userActivities.first { $0.activityType == ConnectionsViewController.activityType }
            ?? session.stateRestorationActivity
        if let endpoint = ConnectionsViewController.endpoint(of: activity) {
            scene.title = endpoint.title
            DispatchQueue.main.async { connections.open(endpoint, password: Connections.shared.password(for: endpoint)) }
        }
        #if DEBUG
        if UserDefaults.standard.string(forKey: "ViewerForm") == "ssh" {
            DispatchQueue.main.async { connections.showSSHFormForTesting() }
        }
        // `-ViewerNewWindow <url>`: that server saved as Dev server (its id made from the URL) and
        // opened in a window of its own, from the first window only.
        if let url = UserDefaults.standard.string(forKey: "ViewerNewWindow"), activity == nil, UIApplication.shared.openSessions.count == 1,
           var (endpoint, password) = CHEndpoint.parse(url) {
            endpoint.id = Connections.debugID(for: url)
            endpoint.name = "Dev server"
            Connections.shared.save(endpoint, password: password ?? "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ConnectionsViewController.openInNewWindow(endpoint) }
        }
        // `-ViewerSettings YES`: Settings at launch (for screenshots).
        if UserDefaults.standard.bool(forKey: "ViewerSettings") {
            DispatchQueue.main.async { AppDelegate.presentSettings(from: connections) }
        }
        // `-ViewerForm new`: File > New Connection's form.
        if UserDefaults.standard.string(forKey: "ViewerForm") == "new" {
            DispatchQueue.main.async { connections.newConnection(nil) }
        }
        // `-ViewerURL <url>`: a server opened at launch (not saved); `-ViewerRun <SQL>` run on it.
        if let url = UserDefaults.standard.string(forKey: "ViewerURL"), var (endpoint, password) = CHEndpoint.parse(url) {
            endpoint.id = Connections.debugID(for: url)
            Connections.debugBastion(for: &endpoint)
            endpoint.environment = UserDefaults.standard.string(forKey: "ViewerEnvironment").flatMap(CHEnvironment.init(rawValue:))
            DispatchQueue.main.async { connections.open(endpoint, password: password ?? "") }
        }
        #endif
    }

    /// The connection the window shows, so it comes back to it (a saved one only).
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let connections = (window?.rootViewController as? UINavigationController)?.viewControllers.first as? ConnectionsViewController,
              let endpoint = connections.shownEndpoint, Connections.shared.keeps(endpoint.id) else { return nil }
        return ConnectionsViewController.activity(for: endpoint)
    }

    /// Another window's connection dropped or asked for while this window exists: it opens here.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let endpoint = ConnectionsViewController.endpoint(of: userActivity),
              let connections = (window?.rootViewController as? UINavigationController)?.viewControllers.first as? ConnectionsViewController,
              connections.shownEndpoint == nil else { return }
        connections.open(endpoint, password: Connections.shared.password(for: endpoint))
    }
}
