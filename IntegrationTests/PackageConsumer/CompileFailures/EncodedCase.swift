import Foundation
import GraphEvo

let invalid: GraphValue = .encoded(.init(codec: "custom", version: 1, data: Data()))
