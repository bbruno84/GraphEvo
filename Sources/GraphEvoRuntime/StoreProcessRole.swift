import Foundation

/// Process classification used only to reject native mirroring from app extensions.
enum StoreProcessRole: Sendable {
    case application
    case appExtension

    static var current: StoreProcessRole {
        classify(bundleURL: Bundle.main.bundleURL,
                 hasExtensionConfiguration: Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil)
    }

    static func classify(bundleURL: URL, hasExtensionConfiguration: Bool) -> StoreProcessRole {
        hasExtensionConfiguration || bundleURL.pathExtension.lowercased() == "appex" ? .appExtension : .application
    }

    func validate(_ configuration: StoreConfiguration) throws {
        if configuration.cloudKitContainerIdentifier != nil, self == .appExtension {
            throw StoreRuntimeError.synchronizationUnavailableInExtension
        }
    }
}
