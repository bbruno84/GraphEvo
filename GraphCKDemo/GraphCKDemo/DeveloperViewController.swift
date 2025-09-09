//
//  DeveloperViewController.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import UIKit
import GraphCK

final class DeveloperViewController: UIViewController {
    
    let graph = GraphProvider.shared.graph
    
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

        // Add a visual separator for Stress Test section
        let separator = UIView()
        separator.backgroundColor = UIColor.systemGray4
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)

        let stressTestActions: [(String, Selector)] = [
            ("Create Attachment (1.5MB)", #selector(createLargeAttachment)),
            ("Link to First Note", #selector(linkToFirstNote)),
            ("Log All Attachments", #selector(logAllAttachments)),
            ("Pulisci Tutto", #selector(clearAllTestData))
        ]

        stressTestActions.forEach { title, selector in
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
    
    @objc private func createLargeAttachment() {
        print("📎 Create Attachment (1.5MB)")
        let entity = Entity("Attachment", graph: graph)
        entity[dynamicMember: "title"] = "Large Attachment"
        entity[dynamicMember: "object"] = Data(repeating: 0xAA, count: 1_500_000) // ~1.5 MB
        GraphProvider.shared.graph.sync()
    }

    @objc private func linkToFirstNote() {
        print("🔗 Link Attachment to First Note")
        guard let note = Search<Entity>(graph: graph).where(.type("Note")).sync().first else {
            print("⚠️ No note found")
            return
        }
        guard let attachment = Search<Entity>(graph: graph).where(.type("Attachment")).sync().first else {
            print("⚠️ No attachment found")
            return
        }
        let rel = Relationship("NoteAttachment", graph: graph)
        rel.subject = note
        rel.object = attachment
        GraphProvider.shared.graph.sync()
    }

    @objc private func logAllAttachments() {
        let attachments = Search<Entity>(graph: graph).where(.type("Attachment")).sync()
        print("📦 Attachments: found \(attachments.count)")
        for (i, entity) in attachments.enumerated() {
            let size = (entity[dynamicMember: "object"] as? Data)?.count ?? 0
            print("🔹 [\(i)] title: \(entity[dynamicMember: "title"] ?? "nil"), size: \(size) bytes")
        }
    }

    @objc private func clearAllTestData() {
        
        print("🧽 Clear Notes, Attachments, Relationships")
        Search<Entity>(graph: graph).where(.type("Note")).sync().forEach { $0.delete() }
        Search<Entity>(graph: graph).where(.type("Attachment")).sync().forEach { $0.delete() }
        Search<Relationship>(graph: graph).where(.type("NoteAttachment")).sync().forEach { $0.delete() }
    }
}
