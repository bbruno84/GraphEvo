//
//  GraphContextRegistry.swift
//  GraphEvo
//
//  In-process registry for Graph instances sharing one persistent store.
//

import CoreData

internal final class GraphContextRegistry {
    static let shared = GraphContextRegistry()

    private final class WeakGraph {
        weak var value: Graph?
        init(_ value: Graph) { self.value = value }
    }

    private final class Entry {
        let context: NSManagedObjectContext
        let container: NSPersistentContainer?
        var configuration: GraphStoreConfiguration
        var observerOwner: Graph?
        var graphs: [WeakGraph]

        init(
            context: NSManagedObjectContext,
            container: NSPersistentContainer?,
            configuration: GraphStoreConfiguration,
            graph: Graph
        ) {
            self.context = context
            self.container = container
            self.configuration = configuration
            self.observerOwner = nil
            self.graphs = [WeakGraph(graph)]
        }
    }

    private let lock = NSLock()
    private let storeOpenLock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    /// Core Data must not initialize two persistent containers for the same
    /// SQLite URL concurrently.
    func withStoreOpenLock<T>(_ body: () throws -> T) rethrows -> T {
        storeOpenLock.lock()
        defer { storeOpenLock.unlock() }
        return try body()
    }

    func context(for key: String) -> NSManagedObjectContext? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.context
    }

    func container(for key: String) -> NSPersistentContainer? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.container
    }

    func configuration(for context: NSManagedObjectContext) -> GraphStoreConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.first(where: { $0.context === context })?.configuration
    }

    /// Registers a Graph atomically with the store identity.
    func register(
        graph: Graph,
        key: String,
        context: NSManagedObjectContext,
        container: NSPersistentContainer?,
        configuration: GraphStoreConfiguration
    ) {
        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[key] {
            entry.configuration = configuration
            if !entry.graphs.contains(where: { $0.value === graph }) {
                entry.graphs.append(WeakGraph(graph))
            }
            return
        }

        entries[key] = Entry(
            context: context,
            container: container,
            configuration: configuration,
            graph: graph
        )
    }

    /// Claims the single remote observer slot for a store.
    func claimObserver(graph: Graph, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.observerOwner == nil else { return false }
        entry.observerOwner = graph
        return true
    }

    /// Releases a Graph and returns the next observer owner when needed.
    func release(graph: Graph, key: String) -> Graph? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }
        entry.graphs = entry.graphs.filter { $0.value != nil && $0.value !== graph }

        let wasObserverOwner = entry.observerOwner === graph
        if wasObserverOwner {
            entry.observerOwner = nil
        }
        if let next = entry.graphs.first?.value {
            return wasObserverOwner ? next : nil
        }

        entries.removeValue(forKey: key)
        return nil
    }

    func removeStore(forKey key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }
}
