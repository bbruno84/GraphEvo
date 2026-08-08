//
//  MainTabBarController.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//

import UIKit

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        tabBar.barTintColor = .systemBackground
        tabBar.tintColor = .label
        tabBar.unselectedItemTintColor = .secondaryLabel

        if UIDevice.current.userInterfaceIdiom == .pad {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.stackedLayoutAppearance.normal.iconColor = .secondaryLabel
            appearance.stackedLayoutAppearance.selected.iconColor = .label
            appearance.inlineLayoutAppearance.normal.iconColor = .secondaryLabel
            appearance.inlineLayoutAppearance.selected.iconColor = .label
            appearance.compactInlineLayoutAppearance.normal.iconColor = .secondaryLabel
            appearance.compactInlineLayoutAppearance.selected.iconColor = .label
            tabBar.standardAppearance = appearance
            if #available(iOS 15.0, *) {
                tabBar.scrollEdgeAppearance = appearance
            }
        }

        let notesImage = UIImage(systemName: "pencil") ?? {
            print("❌ Icon 'pencil' not found; using fallback")
            return UIImage(systemName: "questionmark.circle")!
        }()

        let devImage = UIImage(systemName: "wrench.and.screwdriver") ?? {
            print("❌ Icon 'wrench.and.screwdriver' not found; using fallback")
            return UIImage(systemName: "questionmark.circle")!
        }()

        let notesVC = NotesViewController()
        notesVC.tabBarItem = UITabBarItem(title: "Notes", image: notesImage, tag: 0)

        let devVC = DeveloperViewController()
        devVC.tabBarItem = UITabBarItem(title: "Developer", image: devImage, tag: 1)

        viewControllers = [
            UINavigationController(rootViewController: notesVC),
            UINavigationController(rootViewController: devVC)
        ]
    }
}
