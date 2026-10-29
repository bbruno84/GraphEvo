import UIKit

@MainActor final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func sceneDidBecomeActive(_ scene: UIScene) { ProbeLaunchReceipt.mark("sceneDidBecomeActive") }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        ProbeLaunchReceipt.mark("sceneWillConnect")
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        if let probe = (UIApplication.shared.delegate as? AppDelegate)?.probe {
            window.rootViewController = UINavigationController(rootViewController: probe)
        } else {
            let controller = UIViewController()
            let text = UITextView(); text.text = "Launch with an explicit public probe request."; text.isEditable = false
            controller.view = text; window.rootViewController = controller
        }
        self.window = window; window.makeKeyAndVisible()
        ProbeLaunchReceipt.mark("windowVisible")
    }
}
