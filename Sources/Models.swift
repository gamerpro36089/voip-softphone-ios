import Foundation

enum PresenceStatus: String, Codable, CaseIterable, Identifiable {
    case available = "Available"
    case busy = "Busy"
    case dnd = "Do Not Disturb"
    case away = "Away"

    var id: String { rawValue }
}

struct UserAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var username: String
    var password: String
    var displayName: String
    var extensionNumber: String
    var department: String
    var isAdmin: Bool
    var isDisabled: Bool
    var forceRecording: Bool
    var updatedAt: Date
}

struct IVROption: Identifiable, Codable, Equatable {
    let id: UUID
    var digit: String
    var label: String
    var targetExtension: String
}

struct CallQueue: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var extensionNumber: String
    var memberExtensions: [String]
    var ringStrategy: String
}

struct PBXSettings: Codable, Equatable {
    var companyName: String
    var ivrEnabled: Bool
    var ivrGreeting: String
    var ivrOptions: [IVROption]
    var allowSelfSignup: Bool
    var globalRecording: Bool
    var businessHoursEnabled: Bool
    var openHour: Int
    var closeHour: Int
    var updatedAt: Date
}

struct ParkedCall: Identifiable, Codable, Equatable {
    let id: UUID
    var slot: String
    var callerName: String
    var callerExtension: String
    var parkedByExtension: String
    var parkedAt: Date
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var fromExtension: String
    var fromName: String
    var toExtension: String
    var body: String
    var timestamp: Date
}

struct VoicemailRecording: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var fromExtension: String
    var fromName: String
    var kind: String
    var fileName: String
    var duration: TimeInterval
    var timestamp: Date
    var isRead: Bool
}

enum CallDirection: String, Codable {
    case inbound
    case outbound
}

enum CallState: String {
    case ringing = "Ringing..."
    case connecting = "Connecting..."
    case active = "Active"
    case held = "On Hold"
    case ivr = "Auto-Attendant"
    case voicemail = "Leaving Voicemail"
    case ended = "Ended"
}

struct ActiveCall: Identifiable {
    let id: UUID
    var peerId: String?
    var handle: String
    var displayName: String
    var queueLabel: String?
    let direction: CallDirection
    var state: CallState
    var connectedAt: Date?
    var isMuted: Bool = false
    var isHeld: Bool = false
    var isSpeakerOn: Bool = false
    var isRecording: Bool = false
    var notes: String = ""
}

struct CallLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var handle: String
    var displayName: String
    var queueLabel: String?
    var direction: CallDirection
    var timestamp: Date
    var duration: TimeInterval
    var wasAnswered: Bool
    var notes: String
}

struct DiscoveredPeer: Identifiable, Equatable {
    let id: String
    var name: String
    var extensionNumber: String
    var displayName: String
    var presence: PresenceStatus
    var hostInfo: String
    var isConnected: Bool
}

enum MeshPacketType: String, Codable {
    case hello
    case syncState
    case callInvite
    case callRinging
    case callAnswer
    case callReject
    case callHangup
    case callHold
    case callTransfer
    case callPark
    case dtmf
    case chat
    case adminCommand
    case broadcast
}

struct MeshPacket: Codable {
    var type: MeshPacketType
    var senderPeerId: String
    var senderExtension: String?
    var senderName: String?
    var presence: PresenceStatus?
    var callId: UUID?
    var targetExtension: String?
    var queueLabel: String?
    var boolValue: Bool?
    var textValue: String?
    var chatMessage: ChatMessage?
    var accounts: [UserAccount]?
    var settings: PBXSettings?
    var queues: [CallQueue]?
    var parkedCalls: [ParkedCall]?
}
