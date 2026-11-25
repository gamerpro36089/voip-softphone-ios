import Foundation

enum CallDirection: String, Codable {
    case inbound
    case outbound
}

enum CallState: String {
    case ringing = "Ringing..."
    case connecting = "Connecting..."
    case active = "Active"
    case held = "On Hold"
    case ended = "Ended"
}

struct ActiveCall: Identifiable {
    let id: UUID
    let handle: String
    let displayName: String
    let queueLabel: String?
    let direction: CallDirection
    var state: CallState
    var connectedAt: Date?
    var isMuted: Bool = false
    var isHeld: Bool = false
    var isSpeakerOn: Bool = false
}

struct CallLogEntry: Identifiable, Codable {
    let id: UUID
    let handle: String
    let displayName: String
    let queueLabel: String?
    let direction: CallDirection
    let timestamp: Date
    let duration: TimeInterval
    let wasAnswered: Bool
}
