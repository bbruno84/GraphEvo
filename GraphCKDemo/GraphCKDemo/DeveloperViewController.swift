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
            ("Pulisci Tutto", #selector(clearAllTestData)),
            ("Stress Test", #selector(stressTest)),
            ("DB Dump", #selector(dumpTestSummary))
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

    @objc private func clearAllTestData() {
        
        print("🧽 Clear Notes, Attachments, Relationships")
        graph.clear()
    }
    
    @objc private func stressTest() {
        print("🚀 Inizio stress test...")

        let graph = GraphProvider.shared.graph
        clearAllTestData()

        var createdNotes: [Entity] = []
        var createdAttachments: [Entity] = []
        var favoriteNotes: [Entity] = []
        var totalAttachmentBytes = 0

        let total = Int.random(in: 90...110)
        print("🧮 Numero casuale di note da creare: \(total)")

        for i in 1...total {
            let note = Entity("Note", graph: graph)
            note[dynamicMember: "title"] = "Stress Note \(i)"
            note[dynamicMember: "createdAt"] = Date()

            // 10% probabilità: aggiunta attachment con dimensione random tra 1.5 MB e 2 MB
            if Int.random(in: 1...10) == 1 {
                let attachment = Entity("Attachment", graph: graph)
                attachment[dynamicMember: "title"] = "Attachment \(i)"

                let randomSize = Int.random(in: 1_500_000...2_000_000)
                let data = Data(repeating: 0xBB, count: randomSize)
                attachment[dynamicMember: "object"] = data
                totalAttachmentBytes += data.count

                let rel = Relationship("NoteAttachment", graph: graph)
                rel.object = note
                rel.subject = attachment

                createdAttachments.append(attachment)
            }

            // 25% probabilità: aggiunta tag favorite
            if Bool.random(), Int.random(in: 0...3) == 0 {
                note.add(tags: "favorite")
                favoriteNotes.append(note)
            }

            createdNotes.append(note)
        }

        graph.sync()

        print("🔥 STRESS TEST COMPLETATO 🔥")
        print("📒 Note totali create: \(createdNotes.count)")
        print("🔗 Allegati associati: \(createdAttachments.count)")
        print("⭐️ Note marcate favorite: \(favoriteNotes.count)")
        print("📦 Dimensione totale allegati: \(ByteCountFormatter.string(fromByteCount: Int64(totalAttachmentBytes), countStyle: .file)) (\(totalAttachmentBytes) byte)")
    }
    
    @objc private func dumpTestSummary() {
        let graph = GraphProvider.shared.graph

        let notes = Search<Entity>(graph: graph).where(.type("Note")).sync()
        let attachments = Search<Entity>(graph: graph).where(.type("Attachment")).sync()
        let relationships = Search<Relationship>(graph: graph).where(.type("NoteAttachment")).sync()
        let favorites = notes.filter { $0.has(tags: "favorite") }

        let totalAttachmentBytes = attachments.reduce(0) { sum, entity in
            let data = entity[dynamicMember: "object"] as? Data
            return sum + (data?.count ?? 0)
        }

        print("📊 DUMP DELLO STATO ATTUALE")
        print("📒 Note totali: \(notes.count)")
        print("🔗 Relazioni 'NoteAttachment': \(relationships.count)")
        print("⭐️ Note con tag 'favorite': \(favorites.count)")
        print("📦 Dimensione totale allegati: \(ByteCountFormatter.string(fromByteCount: Int64(totalAttachmentBytes), countStyle: .file)) (\(totalAttachmentBytes) byte)")
    }
}
