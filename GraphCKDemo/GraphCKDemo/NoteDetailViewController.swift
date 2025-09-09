//
//  NoteDetailViewController.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//

import UIKit
import GraphCK

final class NoteDetailViewController: UIViewController {
    let graph: Graph = GraphProvider.shared.graph
    
    private let note: Entity

    init(note: Entity) {
        self.note = note
        super.init(nibName: nil, bundle: nil)
        self.title = "Note Detail"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let label = UILabel()
        label.text = "Title: \(note[dynamicMember: "title"] as? String ?? "—")"
        label.translatesAutoresizingMaskIntoConstraints = false
        
        let attachment = Search<Relationship>(graph: GraphProvider.shared.graph).where(.type("NoteAttachment")).sync().first{ $0.object == note }
        debugPrint("Attachment: \(attachment)")
        let attachLabel = UILabel()
        attachLabel.text = attachment != nil ? "🔗 Attachment: ✅" : "🔗 Attachment: ❌"
        attachLabel.translatesAutoresizingMaskIntoConstraints = false

        let attachmentDetailLabel = UILabel()
        if let attachmentEntity = attachment?.subject {
            let title = attachmentEntity[dynamicMember: "title"] as? String ?? "—"
            let size = (attachmentEntity[dynamicMember: "object"] as? Data)?.count ?? 0
            attachmentDetailLabel.text = "Title: \(title), Size: \(size) bytes"
        } else {
            attachmentDetailLabel.text = "No attachment details"
        }
        attachmentDetailLabel.numberOfLines = 0
        attachmentDetailLabel.font = .systemFont(ofSize: 14)
        attachmentDetailLabel.textColor = .secondaryLabel
        attachmentDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let addButton = UIButton(type: .system)
        addButton.setTitle("Add Attachment", for: .normal)
        addButton.addTarget(self, action: #selector(addAttachment), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let tagButton = UIButton(type: .system)
        tagButton.setTitle("Check Favorite Tag", for: .normal)
        tagButton.addTarget(self, action: #selector(checkFavoriteTag), for: .touchUpInside)
        tagButton.translatesAutoresizingMaskIntoConstraints = false

        let toggleTagButton = UIButton(type: .system)
        toggleTagButton.setTitle("Toggle Favorite", for: .normal)
        toggleTagButton.addTarget(self, action: #selector(toggleFavoriteTag), for: .touchUpInside)
        toggleTagButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [label, attachLabel, attachmentDetailLabel, addButton, tagButton, toggleTagButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func addAttachment() {
        let attachment = Entity("Attachment", graph: graph)
        attachment[dynamicMember: "title"] = "Auto-gen"
        attachment[dynamicMember: "object"] = Data(repeating: 0xFF, count: 1_500_000)

        let rel = Relationship("NoteAttachment", graph: graph)
        rel.object = note
        rel.subject = attachment

        GraphProvider.shared.graph.sync()
        dismiss(animated: true)
    }

    @objc private func checkFavoriteTag() {
        let hasFavorite = note.has(tags: "favorite")
        let alert = UIAlertController(title: "Favorite Tag", message: hasFavorite ? "✅ This note is a favorite." : "❌ Not a favorite.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func toggleFavoriteTag() {
        if note.has(tags: "favorite") {
            note.remove(tags: "favorite")
        } else {
            note.add(tags: "favorite")
        }
        GraphProvider.shared.graph.sync()
    }
}
