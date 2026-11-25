import Foundation
import Combine

final class PBXStore: ObservableObject {
    static let shared = PBXStore()

    @Published var accounts: [UserAccount] = []
    @Published var currentUser: UserAccount?
    @Published var presence: PresenceStatus = .available
    @Published var settings: PBXSettings
    @Published var queues: [CallQueue] = []
    @Published var parkedCalls: [ParkedCall] = []
    @Published var messages: [ChatMessage] = []
    @Published var recordings: [VoicemailRecording] = []
    @Published var callHistory: [CallLogEntry] = []
    @Published var broadcastBanner: String?

    private let defaults = UserDefaults.standard
    private let accountsKey = "meshpbx_accounts_v1"
    private let currentUserIdKey = "meshpbx_current_uid_v1"
    private let settingsKey = "meshpbx_settings_v1"
    private let queuesKey = "meshpbx_queues_v1"
    private let messagesKey = "meshpbx_messages_v1"
    private let recordingsKey = "meshpbx_recordings_v1"
    private let historyKey = "meshpbx_history_v1"

    private init() {
        self.settings = PBXSettings(
            companyName: "MeshPBX Phone",
            ivrEnabled: true,
            ivrGreeting: "Welcome to Mesh P B X. Press 1 for Sales, 2 for Support, 3 for Admin, or 9 to leave a voicemail.",
            ivrOptions: [
                IVROption(id: UUID(), digit: "1", label: "Sales Queue", targetExtension: "801"),
                IVROption(id: UUID(), digit: "2", label: "Support Queue", targetExtension: "800"),
                IVROption(id: UUID(), digit: "3", label: "Admin Desk", targetExtension: "100"),
                IVROption(id: UUID(), digit: "9", label: "Voicemail Box", targetExtension: "VM")
            ],
            allowSelfSignup: true,
            globalRecording: false,
            businessHoursEnabled: false,
            openHour: 8,
            closeHour: 18,
            updatedAt: Date()
        )
        loadAll()
        ensureDefaultSeed()
    }

    private func ensureDefaultSeed() {
        if !accounts.contains(where: { $0.username.lowercased() == "admin" }) {
            let admin = UserAccount(
                id: UUID(),
                username: "admin",
                password: "admin",
                displayName: "System Admin",
                extensionNumber: "100",
                department: "Administration",
                isAdmin: true,
                isDisabled: false,
                forceRecording: false,
                updatedAt: Date()
            )
            accounts.insert(admin, at: 0)
        }

        if queues.isEmpty {
            queues = [
                CallQueue(id: UUID(), name: "Support Queue", extensionNumber: "800", memberExtensions: ["100", "101"], ringStrategy: "Simultaneous"),
                CallQueue(id: UUID(), name: "Sales Queue", extensionNumber: "801", memberExtensions: ["100", "102"], ringStrategy: "Simultaneous")
            ]
        }

        if let savedIdStr = defaults.string(forKey: currentUserIdKey),
           let savedId = UUID(uuidString: savedIdStr),
           let match = accounts.first(where: { $0.id == savedId && !$0.isDisabled }) {
            currentUser = match
        }
        saveAll()
    }

    func loadAll() {
        if let data = defaults.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([UserAccount].self, from: data) {
            accounts = decoded
        }
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(PBXSettings.self, from: data) {
            settings = decoded
        }
        if let data = defaults.data(forKey: queuesKey),
           let decoded = try? JSONDecoder().decode([CallQueue].self, from: data) {
            queues = decoded
        }
        if let data = defaults.data(forKey: messagesKey),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = decoded
        }
        if let data = defaults.data(forKey: recordingsKey),
           let decoded = try? JSONDecoder().decode([VoicemailRecording].self, from: data) {
            recordings = decoded
        }
        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([CallLogEntry].self, from: data) {
            callHistory = decoded
        }
    }

    func saveAll() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: accountsKey) }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
        if let data = try? JSONEncoder().encode(queues) { defaults.set(data, forKey: queuesKey) }
        if let data = try? JSONEncoder().encode(messages) { defaults.set(data, forKey: messagesKey) }
        if let data = try? JSONEncoder().encode(recordings) { defaults.set(data, forKey: recordingsKey) }
        if let data = try? JSONEncoder().encode(callHistory) { defaults.set(data, forKey: historyKey) }
        defaults.set(currentUser?.id.uuidString, forKey: currentUserIdKey)
    }

    func signIn(username: String, password: String) -> String? {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let account = accounts.first(where: { $0.username.lowercased() == cleanUser }) else {
            return "Account not found."
        }
        guard account.password == password else {
            return "Incorrect password."
        }
        guard !account.isDisabled else {
            return "This account has been disabled by an administrator."
        }
        currentUser = account
        presence = .available
        saveAll()
        MeshPBXServer.shared.restartServer()
        return nil
    }

    func signUp(username: String, password: String, displayName: String, department: String) -> String? {
        guard settings.allowSelfSignup else {
            return "Account self-registration is currently disabled by Admin."
        }
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanUser.count >= 2 else { return "Username must be at least 2 characters." }
        guard password.count >= 3 else { return "Password must be at least 3 characters." }
        guard !accounts.contains(where: { $0.username.lowercased() == cleanUser }) else {
            return "Username already exists."
        }

        let ext = nextAvailableExtension()
        let newAccount = UserAccount(
            id: UUID(),
            username: cleanUser,
            password: password,
            displayName: displayName.isEmpty ? cleanUser.capitalized : displayName,
            extensionNumber: ext,
            department: department.isEmpty ? "General" : department,
            isAdmin: false,
            isDisabled: false,
            forceRecording: false,
            updatedAt: Date()
        )
        accounts.append(newAccount)
        currentUser = newAccount
        saveAll()
        MeshPBXServer.shared.restartServer()
        MeshPBXServer.shared.broadcastSyncState()
        return nil
    }

    func signOut() {
        currentUser = nil
        defaults.removeObject(forKey: currentUserIdKey)
        MeshPBXServer.shared.stopServer()
    }

    func nextAvailableExtension() -> String {
        let used = Set(accounts.map { $0.extensionNumber })
        for num in 101...699 {
            let candidate = String(num)
            if !used.contains(candidate) { return candidate }
        }
        return String(Int.random(in: 2000...8999))
    }

    func adminCreateAccount(username: String, password: String, displayName: String, ext: String, department: String, isAdmin: Bool) -> String? {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanUser.isEmpty, !password.isEmpty else { return "Username and password required." }
        guard !accounts.contains(where: { $0.username.lowercased() == cleanUser }) else { return "Username exists." }

        let finalExt = ext.isEmpty ? nextAvailableExtension() : ext
        let acct = UserAccount(
            id: UUID(),
            username: cleanUser,
            password: password,
            displayName: displayName.isEmpty ? cleanUser.capitalized : displayName,
            extensionNumber: finalExt,
            department: department.isEmpty ? "General" : department,
            isAdmin: isAdmin,
            isDisabled: false,
            forceRecording: false,
            updatedAt: Date()
        )
        accounts.append(acct)
        saveAll()
        MeshPBXServer.shared.broadcastSyncState()
        return nil
    }

    func updateAccount(_ updated: UserAccount) {
        var mod = updated
        mod.updatedAt = Date()
        if let idx = accounts.firstIndex(where: { $0.id == mod.id }) {
            accounts[idx] = mod
            if currentUser?.id == mod.id {
                currentUser = mod
            }
            saveAll()
            MeshPBXServer.shared.broadcastSyncState()
        }
    }

    func deleteAccount(_ account: UserAccount) {
        guard account.username.lowercased() != "admin" else { return }
        accounts.removeAll { $0.id == account.id }
        saveAll()
        MeshPBXServer.shared.broadcastSyncState()
    }

    func updateSettings(_ newSettings: PBXSettings) {
        var mod = newSettings
        mod.updatedAt = Date()
        settings = mod
        saveAll()
        MeshPBXServer.shared.broadcastSyncState()
    }

    func addQueue(name: String, ext: String, members: [String]) {
        let q = CallQueue(id: UUID(), name: name, extensionNumber: ext, memberExtensions: members, ringStrategy: "Simultaneous")
        queues.append(q)
        saveAll()
        MeshPBXServer.shared.broadcastSyncState()
    }

    func deleteQueue(_ queue: CallQueue) {
        queues.removeAll { $0.id == queue.id }
        saveAll()
        MeshPBXServer.shared.broadcastSyncState()
    }

    func addMessage(_ msg: ChatMessage) {
        if !messages.contains(where: { $0.id == msg.id }) {
            messages.append(msg)
            messages.sort { $0.timestamp < $1.timestamp }
            saveAll()
        }
    }

    func addRecording(_ rec: VoicemailRecording) {
        recordings.insert(rec, at: 0)
        saveAll()
    }

    func deleteRecording(_ rec: VoicemailRecording) {
        try? FileManager.default.removeItem(at: VoiceAudioEngine.shared.recordingURL(for: rec.fileName))
        recordings.removeAll { $0.id == rec.id }
        saveAll()
    }

    func addCallLog(_ entry: CallLogEntry) {
        callHistory.insert(entry, at: 0)
        saveAll()
    }

    func nextFreeParkSlot() -> String? {
        let used = Set(parkedCalls.map { $0.slot })
        for slot in ["701", "702", "703", "704"] {
            if !used.contains(slot) { return slot }
        }
        return nil
    }

    func parkCall(callerName: String, callerExt: String, byExt: String) -> String? {
        guard let slot = nextFreeParkSlot() else { return nil }
        let parked = ParkedCall(id: UUID(), slot: slot, callerName: callerName, callerExtension: callerExt, parkedByExtension: byExt, parkedAt: Date())
        parkedCalls.append(parked)
        MeshPBXServer.shared.broadcastSyncState()
        return slot
    }

    func unparkSlot(_ slot: String) -> ParkedCall? {
        guard let idx = parkedCalls.firstIndex(where: { $0.slot == slot }) else { return nil }
        let item = parkedCalls.remove(at: idx)
        MeshPBXServer.shared.broadcastSyncState()
        return item
    }

    func mergeSync(accounts remoteAccounts: [UserAccount]?, settings remoteSettings: PBXSettings?, queues remoteQueues: [CallQueue]?, parkedCalls remoteParked: [ParkedCall]?) {
        var changed = false

        if let remoteAccounts = remoteAccounts {
            for r in remoteAccounts {
                if let idx = accounts.firstIndex(where: { $0.username.lowercased() == r.username.lowercased() }) {
                    if r.updatedAt > accounts[idx].updatedAt {
                        accounts[idx] = r
                        changed = true
                    }
                } else {
                    accounts.append(r)
                    changed = true
                }
            }
            if let cur = currentUser, let refreshed = accounts.first(where: { $0.username.lowercased() == cur.username.lowercased() }) {
                if refreshed.isDisabled {
                    signOut()
                } else {
                    currentUser = refreshed
                }
            }
        }

        if let remoteSettings = remoteSettings, remoteSettings.updatedAt > settings.updatedAt {
            settings = remoteSettings
            changed = true
        }

        if let remoteQueues = remoteQueues, !remoteQueues.isEmpty {
            for rq in remoteQueues {
                if !queues.contains(where: { $0.extensionNumber == rq.extensionNumber }) {
                    queues.append(rq)
                    changed = true
                }
            }
        }

        if let remoteParked = remoteParked {
            parkedCalls = remoteParked
        }

        if changed {
            saveAll()
        }
    }

    func isWithinBusinessHours() -> Bool {
        guard settings.businessHoursEnabled else { return true }
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= settings.openHour && hour < settings.closeHour
    }
}
