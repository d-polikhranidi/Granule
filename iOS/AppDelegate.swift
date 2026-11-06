import UIKit

/// The iPad and iPhone app: each window (scene) lists the connections and
/// opens one into its schema, editor and result (see `SceneDelegate`).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GinghamKey.register()
        return true
    }

    /// The menu bar (iPadOS 26 shows every command there, dimmed when it can't run)
    /// and the keyboard's shortcuts: New Connection, the Query menu, Find in Result, Show Chart.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: String(localized: "New Connection"), action: #selector(ConnectionsViewController.newConnection(_:)), input: "n", modifierFlags: .command),
        ]), atStartOfMenu: .file)
        builder.insertSibling(UIMenu(title: String(localized: "Query"), children: [
            UIKeyCommand(title: String(localized: "Run Statement"), action: #selector(QueryViewController.runCommand(_:)), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Stop"), action: #selector(QueryViewController.stopCommand(_:)), input: ".", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Check Statement"), action: #selector(QueryViewController.checkCommand(_:)), input: "b", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Explain Plan"), action: #selector(QueryViewController.explainCommand(_:)), input: "\r",
                         modifierFlags: [.command, .alternate]),
        ]), afterMenu: .view)
        // Find looks in the result (the editor has no find of its own).
        builder.remove(menu: .find)
        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: String(localized: "Find in Result"), action: #selector(QueryViewController.findCommand(_:)), input: "f", modifierFlags: .command),
        ]), atEndOfMenu: .edit)
        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: String(localized: "Show Chart"), action: #selector(QueryViewController.chartCommand(_:)), input: "k", modifierFlags: [.command, .shift]),
        ]), atStartOfMenu: .view)
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
