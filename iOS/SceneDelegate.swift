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
        #if DEBUG
        if UserDefaults.standard.string(forKey: "ViewerForm") == "ssh" {
            DispatchQueue.main.async { connections.showSSHFormForTesting() }
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
}
