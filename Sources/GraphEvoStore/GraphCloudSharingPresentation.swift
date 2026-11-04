import CloudKit
import Foundation
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Owns the platform delegate and a connection lease for one native sharing presentation.
/// The host retains this adapter until close completes, and chooses when/where to present.
@available(iOS 17, macOS 14, *)
@MainActor public final class GraphCloudSharingPresentation: NSObject {
    private let connection: GraphCloudConnection
    private let manager: GraphContextManager
    private let token: UUID
    private let share: CKShare
    private let container: CKContainer
    private let title: String
    // AppKit may deliver control callbacks off MainActor; preserve their order before UI completion.
    nonisolated private let nativeStopped = OSAllocatedUnfairLock(initialState: false)
    nonisolated private var stopped: Bool { nativeStopped.withLock { $0 } }
    private var presented = false
    private var nativeCompleted = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var presentationLifetime: GraphCloudSharingPresentation?
    private var closing: Task<Void, any Error>?
    private var observation: Task<Void, Never>?
    /// A bounded presentation/reconciliation failure; native identities are omitted.
    public private(set) var failure: GraphCloudConnectionFailure?
    #if canImport(UIKit)
    private var controller: UICloudSharingController?
    #elseif canImport(AppKit)
    private var service: NSSharingService?
    private weak var source: NSView?
    #endif

    init(connection: GraphCloudConnection, manager: GraphContextManager, token: UUID, archive: Data, containerIdentifier: String, title: String) throws {
        guard let share = try GraphCloudRecordCodec.restore(archive) as? CKShare else { throw GraphCloudDiscoveryError.invalidInvitation }
        self.connection = connection; self.manager = manager; self.token = token
        self.share = share; self.container = CKContainer(identifier: containerIdentifier); self.title = title
        super.init()
        observation = Task { [weak self, connection] in
            do {
                let states = try await connection.observeState()
                for await state in states {
                    guard !Task.isCancelled else { break }
                    if case .isolated = state { try? await self?.close(); break }
                }
            } catch { }
        }
    }
    deinit {
        observation?.cancel()
        if closing == nil {
            let manager = manager, token = token, connection = connection, stopped = stopped
            Task {
                try? await manager.finishNativePresentation(token, stopped: stopped)
                try? await connection.close()
            }
        }
    }
    #if canImport(UIKit)
    /// Presents Apple's private-participant UI. Use a visible host controller.
    public func present(from presenter: UIViewController) throws {
        guard !presented, closing == nil, presenter.viewIfLoaded?.window != nil else { throw GraphCloudDiscoveryError.busy }
        let controller = GraphCloudNativeSharingController(share: share, container: container)
        controller.didDismiss = { [weak self] in self?.completed() }
        controller.availablePermissions = [.allowPrivate, .allowReadOnly, .allowReadWrite]
        controller.delegate = self
        controller.presentationController?.delegate = self
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = presenter.view.bounds
        self.controller = controller; presented = true; presentationLifetime = self
        presenter.present(controller, animated: true)
        controller.presentationController?.delegate = self
    }
    #elseif canImport(AppKit)
    /// Presents Apple's cloud-sharing service anchored to a visible host view.
    public func present(from source: NSView) throws {
        guard !presented, closing == nil, source.window != nil,
              let service = NSSharingService(named: .cloudSharing) else { throw GraphCloudDiscoveryError.busy }
        let provider = NSItemProvider()
        provider.registerCloudKitShare(share, container: container)
        service.delegate = self
        guard service.canPerform(withItems: [provider]) else { throw GraphCloudSharingError.unavailable }
        self.source = source; self.service = service; presented = true; presentationLifetime = self
        service.perform(withItems: [provider])
    }
    #endif
    /// Dismisses the UI and reconciles server metadata before releasing retained ownership.
    public func close() async throws {
        if let closing { return try await closing.value }
        observation?.cancel(); observation = nil
        #if canImport(UIKit)
        if presented, !nativeCompleted {
            controller?.dismiss(animated: true) { [weak self] in self?.markNativeCompleted() }
        }
        #endif
        let manager = manager, token = token, connection = connection, stopped = stopped
        let task = Task {
            await self.waitForNativeCompletion()
            var failure: (any Error)?
            do { try await manager.finishNativePresentation(token, stopped: stopped) } catch { failure = error }
            try await connection.close()
            if let failure { throw failure }
        }
        closing = task
        do { try await task.value }
        catch { closing = nil; failure = GraphCloudConnectionFailure(error); throw error }
    }
    private func waitForNativeCompletion() async {
        if presented, !nativeCompleted { await withCheckedContinuation { completionWaiters.append($0) } }
    }
    private func markNativeCompleted() {
        nativeCompleted = true
        let values = completionWaiters; completionWaiters.removeAll()
        for value in values { value.resume() }
        presentationLifetime = nil
    }
    private func completed(error: (any Error)? = nil) {
        markNativeCompleted()
        if let error { failure = GraphCloudConnectionFailure(error) }
        Task { [self] in try? await close() }
    }
}

#if canImport(UIKit)
@available(iOS 17, macOS 14, *)
@MainActor private final class GraphCloudNativeSharingController: UICloudSharingController {
    var didDismiss: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { didDismiss?() }
    }
}
@available(iOS 17, macOS 14, *)
extension GraphCloudSharingPresentation: UICloudSharingControllerDelegate, UIAdaptivePresentationControllerDelegate {
    public func itemTitle(for csc: UICloudSharingController) -> String? { title }
    public func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: any Error) { failure = .init(error) }
    public func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { completed() }
    public func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { nativeStopped.withLock { $0 = true }; completed() }
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { completed() }
}
#elseif canImport(AppKit)
@available(iOS 17, macOS 14, *)
extension GraphCloudSharingPresentation: NSCloudSharingServiceDelegate {
    nonisolated public func options(for cloudKitSharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadOnly, .allowReadWrite]
    }
    nonisolated public func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: (any Error)?) { Task { @MainActor [weak self] in self?.completed(error: error) } }
    nonisolated public func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) { }
    nonisolated public func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) { nativeStopped.withLock { $0 = true } }
    public func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { source?.window }
}
#endif

@available(iOS 17, macOS 14, *)
extension GraphCloudConnection {
    /// Prepares the fixed graph descriptor and an owner-only native presentation adapter.
    public func prepareSharing(for graph: GraphStore, title: String) async throws -> GraphCloudSharingPresentation {
        try await validateGraph(graph)
        let config = try await ready(), context = owningContext
        let lease = try await context.connectCloud(using: .init(containerIdentifier: config.containerIdentifier, environment: config.environment,
            directory: config.directory, maximumEvents: config.maximumEvents, maximumBytes: config.maximumBytes, allowsSessionUpgradeFromV8: config.allowsSessionUpgradeFromV8))
        do {
            let result = try await context.manager.prepareNativePresentation(graph.id, title: title, configuration: config, publicOwner: graph.publicCoordinatorGeneration)
            do {
                return try await GraphCloudSharingPresentation(connection: lease, manager: context.manager, token: result.0,
                    archive: result.1, containerIdentifier: config.containerIdentifier, title: title)
            } catch {
                try? await context.manager.finishNativePresentation(result.0, stopped: false)
                throw error
            }
        } catch { try? await lease.close(); throw error }
    }
}
