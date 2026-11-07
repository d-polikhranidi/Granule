import SwiftUI
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
        // Settings… in the app menu, where the system puts a Settings bundle's.
        let settings = UIKeyCommand(title: String(localized: "Settings…"), action: #selector(showSettings(_:)), input: ",", modifierFlags: .command)
        if builder.menu(for: .preferences) != nil {
            builder.replaceChildren(ofMenu: .preferences) { _ in [settings] }
        } else if builder.menu(for: .about) != nil {
            builder.insertSibling(UIMenu(options: .displayInline, children: [settings]), afterMenu: .about)
        } else {
            builder.insertChild(UIMenu(options: .displayInline, children: [settings]), atStartOfMenu: .application)
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: String(localized: "New Connection"), action: #selector(ConnectionsViewController.newConnection(_:)), input: "n", modifierFlags: .command),
        ]), atStartOfMenu: .file)
        builder.insertSibling(UIMenu(title: String(localized: "Query"), children: [
            UIKeyCommand(title: String(localized: "Run Statement"), action: #selector(QueryViewController.runCommand(_:)), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Stop"), action: #selector(QueryViewController.stopCommand(_:)), input: ".", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Check Statement"), action: #selector(QueryViewController.checkCommand(_:)), input: "b", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Format Statement"), action: #selector(QueryViewController.formatCommand(_:)), input: "f",
                         modifierFlags: [.control, .shift]),
            UIKeyCommand(title: String(localized: "Query Details"), action: #selector(QueryViewController.detailsCommand(_:)), input: "d",
                         modifierFlags: [.command, .option]),
            UIKeyCommand(title: String(localized: "Save Query…"), action: #selector(QueryViewController.saveQueryCommand(_:)), input: "s", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Saved Queries and History…"), action: #selector(QueryViewController.libraryCommand(_:)), input: "y",
                         modifierFlags: .command),
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

    /// Settings… (⌘,): over the window in front, wherever it is.
    @objc func showSettings(_ sender: Any?) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        Self.presentSettings(from: top)
    }

    /// Settings > Appearance in a sheet: the editor's theme and size, the result's look.
    static func presentSettings(from controller: UIViewController) {
        let settings = UIHostingController(rootView: AppearanceSettingsView())
        settings.title = String(localized: "Settings")
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak settings] _ in
            settings?.dismiss(animated: true)
        })
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .formSheet
        controller.present(navigation, animated: true)
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
