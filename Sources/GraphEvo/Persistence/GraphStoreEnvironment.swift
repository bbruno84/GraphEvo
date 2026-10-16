import Foundation
#if os(macOS)
import Security
#endif

/// The persistence environment selected for a Graph store.
public enum GraphStoreEnvironment: String, Codable, Equatable, Sendable {
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

#if os(macOS)
        if let entitlementValue {
            switch entitlementValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "Development": return .success(.development)
            case "Production": return .success(.production)
            default: break
            }
        }
#endif

#if os(iOS)
#if targetEnvironment(simulator)
        let isSimulator = true
#else
        let isSimulator = false
#endif
#if DEBUG
        let isDebugBuild = true
#else
        let isDebugBuild = false
#endif
        return .success(environmentForIOSBuild(
            isSimulator: isSimulator,
            isDebugBuild: isDebugBuild
        ))
#else
        return .failure(.cloudKitEnvironmentUnavailable)
#endif
    }

    /// CloudKit follows the signed entitlement selected by Xcode. GraphEvo keeps
    /// its store namespace aligned without inspecting that entitlement through
    /// private iOS APIs: simulator and Debug builds use Development, while
    /// optimized device builds use Production.
    static func environmentForIOSBuild(
        isSimulator: Bool,
        isDebugBuild: Bool
    ) -> GraphStoreEnvironment {
        isSimulator || isDebugBuild ? .development : .production
    }

    private static func readEntitlement() -> String? {
#if os(macOS)
        readEntitlementValue(for: entitlementKey) as? String
#else
        nil
#endif
    }

#if os(macOS)
    private static func readEntitlementValue(for key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task,
            key as CFString,
            nil
        )
    }
#endif
}
