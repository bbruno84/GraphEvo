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

        let notesVC = NotesViewController()
        notesVC.tabBarItem = UITabBarItem(title: "Notes", image: .init(systemName: "note.text.badge.plus"), tag: 0)

        let devVC = DeveloperViewController()
        devVC.tabBarItem = UITabBarItem(title: "Developer", image: .init(systemName: "wrench.and.screwdriver"), tag: 1)

        viewControllers = [UINavigationController(rootViewController: notesVC),
                           UINavigationController(rootViewController: devVC)]
    }
}
