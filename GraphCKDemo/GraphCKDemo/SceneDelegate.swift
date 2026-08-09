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
        let tabBarController = MainTabBarController()
        window.rootViewController = tabBarController
        self.window = window
        window.makeKeyAndVisible()
    }
}
