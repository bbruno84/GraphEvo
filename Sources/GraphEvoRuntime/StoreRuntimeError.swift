import Foundation

/// Typed local runtime failures; successful local opening never certifies cloud synchronization.
package enum StoreRuntimeError: Error {
    case invalidConfiguration(String)
    case invalidModel(String)
    case configurationConflict(URL?)
    case incompatibleStore(URL)
    case unsupportedFileAlias(URL)
    case storeReplaced(URL)
    case loadFailed(URL?, underlying: any Error)
    case shutdownFailed(URL?, underlying: any Error)
    case closedHandle
    case mutationInReadScope
}

extension StoreRuntimeError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): return "Invalid store configuration: \(reason)"
        case .invalidModel(let identifier): return "The store model does not match its declared identity: \(identifier)."
        case .configurationConflict: return "The store already has an incompatible runtime owner."
        case .incompatibleStore: return "The existing store requires an explicit data migration."
        case .unsupportedFileAlias: return "The SQLite file uses an unsupported filesystem alias."
        case .storeReplaced: return "The SQLite file changed identity while owned by this runtime."
        case .loadFailed: return "The persistent store could not be loaded."
        case .shutdownFailed: return "The store could not be detached; its runtime ownership is retained."
        case .closedHandle: return "The store handle is closed."
        case .mutationInReadScope: return "A read operation attempted to change persistent data."
        }
    }
}
