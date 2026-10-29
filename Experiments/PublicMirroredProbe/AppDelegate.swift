import UIKit

/// The disposable CLI host owns work independently of scene visibility.
@main @MainActor final class AppDelegate: UIResponder, UIApplicationDelegate {
    private(set) var probe: UIViewController?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--native-diagnose") {
            let controller = PublicMirroredDiagnosticsViewController(arguments: args)
            probe = controller; controller.startProbe()
        } else if args.contains("--native-public") {
            let controller = PublicMirroredProbeViewController(arguments: args)
            probe = controller; controller.startProbe()
        } else if args.contains("--a6") {
            let controller = A6NativeProbeViewController(arguments: args)
            probe = controller; controller.startProbe()
        }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Native Public Consumer", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.newData)
    }
}
