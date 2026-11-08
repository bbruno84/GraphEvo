import Foundation
import GraphEvo

// Raw bytes must use GraphAttachmentValue, never the property conversion protocol.
let invalid = Data([0, 255]).graphValue
