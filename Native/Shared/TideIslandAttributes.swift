import ActivityKit
import Foundation
import TideIslandCore

struct TideIslandAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var sessionID: String
        var projectName: String
        var phase: AgentPhase
        var workingCount: Int
        var waitingCount: Int
        var updatedAt: Date
    }

    var name: String = "TideIsland"
}
