import Foundation
import Security

/// The persistence environment selected for a Graph store.
public enum GraphStoreEnvironment: String, Equatable {
    case development
    case production
    case local
}

internal enum GraphStoreEnvironmentResolver {
    static let entitlementKey = "com.apple.developer.icloud-container-environment"

    static func resolve(
        configuration: GraphStoreConfiguration,
        entitlementValue: String? = readEntitlement(),
        runningUnderTests: Bool = Graph.isRunningUnderTests
    ) -> Result<GraphStoreEnvironment, GraphStoreOpeningError> {
        if configuration.disablesCloudKit || configuration.cloudKitContainerIdentifier == nil {
            return .success(.local)
        }

        // Test bundles intentionally use local Core Data containers. Treat
        // their CloudKit configurations as development for deterministic paths.
        if runningUnderTests {
            return .success(.development)
        }

        if let entitlementValue {
            switch entitlementValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "Development": return .success(.development)
            case "Production": return .success(.production)
            default: break
            }
        }

#if os(iOS) && targetEnvironment(simulator)
        return .success(.development)
#else
        return .failure(.cloudKitEnvironmentUnavailable)
#endif
    }

    private static func readEntitlement() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task,
            entitlementKey as CFString,
            nil
        ) as? String
    }
}
