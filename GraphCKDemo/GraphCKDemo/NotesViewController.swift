//
//  NotesViewController.swift
//  GraphCKDemo
//
//  Created by Valerio Buriani on 09/09/25.
//


import UIKit
import GraphEvo

final class NotesViewController: UIViewController {

    private var notes: [Entity] = []
    private var tableView: UITableView!
    private let reuseIdentifier = "NoteCell"
    private let refreshControl = UIRefreshControl()
    
    private var watcher: Watch<Entity>?
    private var strongWatcher: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
                
        
        title = "Notes"
        view.backgroundColor = .systemBackground

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(graphStateChanged),
            name: .graphProviderStateDidChange,
            object: GraphProvider.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        configureTableView()
        configureNavBar()
        loadNotes()
        setupWatcher()
        print("🧩 NotesViewController viewDidLoad completed. Frame: \(view.frame)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if UIDevice.current.userInterfaceIdiom == .pad {
            navigationController?.navigationBar.prefersLargeTitles = true
            navigationItem.largeTitleDisplayMode = .always
        } else {
            navigationController?.navigationBar.prefersLargeTitles = false
            navigationItem.largeTitleDisplayMode = .never
        }

        loadNotes()
    }

    // MARK: - UI Setup

    private func configureTableView() {
        tableView = UITableView(frame: view.bounds)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        refreshControl.addTarget(self, action: #selector(refreshNotes), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)
        print("🪑 TableView added to view with frame: \(tableView.frame)")
    }

    private func configureNavBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addNote)
        )
    }

    // MARK: - Data

    private func loadNotes() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.loadNotes()
            }
            return
        }

        guard let graph = GraphProvider.shared.graphIfReady() else { return }
        notes = Search<Entity>(graph: graph)
            .where(.type("Note"))
            .sync()
        
        notes.sort {
            ($0[dynamicMember: "createdAt"] as? Date ?? .distantPast)
                > ($1[dynamicMember: "createdAt"] as? Date ?? .distantPast)
        }
        tableView.reloadData()
    }

    @objc private func refreshNotes() {
        loadNotes()
        refreshControl.endRefreshing()
    }

    @objc private func addNote() {
        guard let graph = GraphProvider.shared.graphIfReady() else { return }
        let note = Entity("Note", graph: graph)
        note[dynamicMember: "title"] = "Note at \(Date())"
        note[dynamicMember: "createdAt"] = Date()
        note.add(tags: "inbox")
        graph.sync()
    }

    private func deleteNote(at index: Int) {
        guard let graph = GraphProvider.shared.graphIfReady() else { return }
        guard notes.indices.contains(index) else { return }
        let note = notes[index]
        note.delete()
        graph.sync()
        loadNotes()
    }

    private func toggleFavorite(_ note: Entity) {
        if note.has(tags: "favorite") {
            note.remove(tags: "favorite")
        } else {
            note.add(tags: "favorite")
        }
        guard let graph = GraphProvider.shared.graphIfReady() else { return }
        graph.sync()
    }

    // MARK: - Watchers

    private func setupWatcher() {
        guard let graph = GraphProvider.shared.graphIfReady() else { return }
        let watcher = Watch<Entity>(graph: graph).where(.type("Note"))
        watcher.delegate = self
        self.watcher = watcher
        self.strongWatcher = watcher  // 👈 mantiene la reference forte
        print("👀 Watcher setup completed")
    }

    @objc private func graphStateChanged() {
        guard GraphProvider.shared.isReady else { return }
        loadNotes()
        if watcher == nil {
            setupWatcher()
        }
    }

    @objc private func applicationDidBecomeActive() {
        loadNotes()
    }
}

// MARK: - UITableViewDataSource

extension NotesViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView,
                   numberOfRowsInSection section: Int) -> Int {
        return notes.count
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let note = notes[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier, for: indexPath)

        let title = note[dynamicMember: "title"] as? String ?? "Untitled"
        let isFavorite = note.has(tags: "favorite")
        cell.textLabel?.text = title + (isFavorite ? " ★" : "")
        return cell
    }
}

// MARK: - UITableViewDelegate

extension NotesViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView,
                   didSelectRowAt indexPath: IndexPath) {
        let note = notes[indexPath.row]
        let detailVC = NoteDetailViewController(note: note)
        let nav = UINavigationController(rootViewController: detailVC)
        present(nav, animated: true)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            deleteNote(at: indexPath.row)
        }
    }
}

// MARK: - GraphEntityDelegate

extension NotesViewController: GraphEntityDelegate {

    func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
        print("📥 Inserted \(entity.type) from: \(source)")
        loadNotes()
    }

    func graph(_ graph: Graph, updated entity: Entity, source: GraphSource) {
        print("✏️ Updated \(entity.type) from: \(source)")
        loadNotes()
    }

    func graph(_ graph: Graph, deleted entity: Entity, source: GraphSource) {
        print("🗑️ Deleted \(entity.type) from: \(source)")
        loadNotes()
    }
}
