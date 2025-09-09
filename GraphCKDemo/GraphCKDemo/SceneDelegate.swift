//
//  SceneDelegate 2.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {

        guard let windowScene = scene as? UIWindowScene else {
            print("❌ Not a UIWindowScene")
            return
        }

        print("✅ SceneDelegate started")

        let window = UIWindow(windowScene: windowScene)
        let tabBarController = UITabBarController()

        let notesVC = NotesViewController()
        notesVC.tabBarItem = UITabBarItem(title: "Notes", image: nil, tag: 0)

        let developerVC = DeveloperViewController()
        developerVC.view.backgroundColor = .systemBackground
        developerVC.tabBarItem = UITabBarItem(title: "Developer", image: nil, tag: 1)

        tabBarController.viewControllers = [
            UINavigationController(rootViewController: notesVC),
            UINavigationController(rootViewController: developerVC)
        ]

        window.rootViewController = tabBarController
        self.window = window
        window.makeKeyAndVisible()
    }
}
