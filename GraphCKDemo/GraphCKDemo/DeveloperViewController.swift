//
//  DeveloperViewController.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import UIKit
import GraphCK

final class DeveloperViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Developer"
        tabBarItem = UITabBarItem(title: "Dev", image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))
        view.backgroundColor = .white
        setupButtons()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("✅ DeveloperViewController is visible")
    }

    private func setupButtons() {
        let actions: [(String, Selector)] = [
            ("Clear Token", #selector(clearToken)),
            ("Print Token Status", #selector(printTokenStatus)),
            ("Print Author & Context", #selector(printAuthorAndContext))
        ]

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        stack.isLayoutMarginsRelativeArrangement = true

        actions.forEach { title, selector in
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor.systemBlue
            button.layer.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.addTarget(self, action: selector, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func clearToken() {
        print("🧹 Developer Action: Clear Token")
        GraphProvider.shared.graph.ph_debug_clearToken()
    }

    @objc private func printTokenStatus() {
        print("📄 Developer Action: Print Token Status")
        GraphProvider.shared.graph.ph_debug_printTokenStatus()
    }

    @objc private func printAuthorAndContext() {
        print("👤 Developer Action: Print Author & Context")
        GraphProvider.shared.graph.ph_debug_printAuthorAndContext()
    }
}
