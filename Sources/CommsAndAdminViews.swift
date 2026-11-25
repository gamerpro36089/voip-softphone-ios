import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var server: MeshPBXServer

    @State private var selectedChannel = "ALL"
    @State private var draft = ""

    private var filteredMessages: [ChatMessage] {
        let myExt = store.currentUser?.extensionNumber ?? ""
        return store.messages.filter { msg in
            if selectedChannel == "ALL" {
                return msg.toExtension == "ALL"
            }
            return (msg.fromExtension == myExt && msg.toExtension == selectedChannel) ||
                   (msg.fromExtension == selectedChannel && msg.toExtension == myExt)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Channel", selection: $selectedChannel) {
                    Text("#General").tag("ALL")
                    ForEach(store.accounts.filter { $0.id != store.currentUser?.id }) { acct in
                        Text("\(acct.displayName) (\(acct.extensionNumber))").tag(acct.extensionNumber)
                    }
                }
                .pickerStyle(.menu)
                .padding(8)

                List(filteredMessages) { msg in
                    let isMine = msg.fromExtension == store.currentUser?.extensionNumber
                    HStack {
                        if isMine { Spacer() }
                        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                            Text("\(msg.fromName) • Ext \(msg.fromExtension)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(msg.body)
                                .padding(10)
                                .background(isMine ? Color.blue : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(isMine ? .white : .primary)
                        }
                        if !isMine { Spacer() }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)

                HStack {
                    TextField("Message...", text: $draft)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        server.sendChat(toExtension: selectedChannel, body: clean)
                        draft = ""
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("Team Chat")
        }
    }
}

struct RecentsView: View {
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        NavigationStack {
            List(store.callHistory) { entry in
                Button {
                    callManager.startCall(to: entry.handle)
                } label: {
                    HStack {
                        Image(systemName: entry.direction == .inbound ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .foregroundStyle(entry.wasAnswered ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName).font(.headline).foregroundStyle(.primary)
                            Text("Ext \(entry.handle)\(entry.queueLabel != nil ? " • \(entry.queueLabel!)" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !entry.notes.isEmpty {
                                Text("Note: \(entry.notes)").font(.caption2).foregroundStyle(.blue)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(Int(entry.duration))s").font(.caption.monospacedDigit())
                            Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Recents")
        }
    }
}

struct VoicemailRecordingsView: View {
    @EnvironmentObject var store: PBXStore
    @ObservedObject private var audio = VoiceAudioEngine.shared

    var body: some View {
        NavigationStack {
            List {
                if store.recordings.isEmpty {
                    Text("No voicemails or call recordings yet. Tap Record during a call or call an offline extension.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.recordings) { rec in
                        HStack {
                            Button {
                                audio.togglePlayback(fileName: rec.fileName)
                            } label: {
                                Image(systemName: audio.playingFileName == rec.fileName ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.title).font(.headline)
                                Text("\(rec.kind) • \(Int(rec.duration))s • \(rec.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            store.deleteRecording(store.recordings[idx])
                        }
                    }
                }
            }
            .navigationTitle("Voicemail & Recs")
        }
    }
}

struct ServerAndAccountView: View {
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var server: MeshPBXServer

    var body: some View {
        NavigationStack {
            List {
                Section("Signed In Account") {
                    LabeledContent("User", value: store.currentUser?.username ?? "-")
                    LabeledContent("Name", value: store.currentUser?.displayName ?? "-")
                    LabeledContent("Extension", value: store.currentUser?.extensionNumber ?? "-")
                    LabeledContent("Role", value: (store.currentUser?.isAdmin ?? false) ? "Super Admin" : "Standard User")
                }

                Section("Embedded Phone Server") {
                    LabeledContent("Status", value: server.statusMessage)
                    LabeledContent("Peer ID", value: server.localPeerId)
                    ForEach(server.localIPs, id: \.ip) { item in
                        LabeledContent("IP (\(item.name))", value: "\(item.ip):\(server.listenPort)")
                    }
                    Button("Restart Phone Server") {
                        server.restartServer()
                    }
                    Button("Force Sync Mesh State") {
                        server.broadcastHello()
                        server.broadcastSyncState()
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        store.signOut()
                    }
                }
            }
            .navigationTitle("Phone Server")
        }
    }
}

struct AdminPanelView: View {
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var server: MeshPBXServer

    @State private var showCreateUser = false
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var newDisplayName = ""
    @State private var newExt = ""
    @State private var newDept = ""
    @State private var newIsAdmin = false
    @State private var createError: String?

    @State private var broadcastText = ""
    @State private var newQueueName = ""
    @State private var newQueueExt = ""
    @State private var newQueueMembers = "100,101"

    var body: some View {
        NavigationStack {
            List {
                Section("Live Broadcast & Mesh Supervision") {
                    HStack {
                        TextField("System-wide alert banner...", text: $broadcastText)
                        Button("Send") {
                            guard !broadcastText.isEmpty else { return }
                            server.sendBroadcastAlert(broadcastText)
                            broadcastText = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ForEach(server.peers) { peer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(peer.displayName) (Ext \(peer.extensionNumber))").font(.subheadline.bold())
                                Text("\(peer.presence.rawValue) • \(peer.hostInfo)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Drop Call") {
                                server.sendAdminCommand("forceHangup", targetExtension: peer.extensionNumber)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .font(.caption)

                            Button("Kick") {
                                server.sendAdminCommand("forceSignOut", targetExtension: peer.extensionNumber)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .font(.caption)
                        }
                    }
                }

                Section("User Accounts & Extensions (\(store.accounts.count))") {
                    Button {
                        showCreateUser = true
                    } label: {
                        Label("Create User Account", systemImage: "person.badge.plus")
                    }

                    ForEach(store.accounts) { acct in
                        NavigationLink {
                            AdminEditUserView(account: acct)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(acct.displayName) (\(acct.username))")
                                        .font(.headline)
                                    Text("Ext \(acct.extensionNumber) • \(acct.department)\(acct.isAdmin ? " • ADMIN" : "")\(acct.isDisabled ? " • DISABLED" : "")")
                                        .font(.caption)
                                        .foregroundStyle(acct.isDisabled ? .red : .secondary)
                                }
                            }
                        }
                    }
                }

                Section("Global PBX & Compliance Controls") {
                    Toggle("Allow New User Signups", isOn: Binding(
                        get: { store.settings.allowSelfSignup },
                        set: { val in
                            var s = store.settings
                            s.allowSelfSignup = val
                            store.updateSettings(s)
                        }
                    ))
                    Toggle("Global Mandatory Call Recording", isOn: Binding(
                        get: { store.settings.globalRecording },
                        set: { val in
                            var s = store.settings
                            s.globalRecording = val
                            store.updateSettings(s)
                        }
                    ))
                    Toggle("Enable Business Hours (\(store.settings.openHour):00–\(store.settings.closeHour):00)", isOn: Binding(
                        get: { store.settings.businessHoursEnabled },
                        set: { val in
                            var s = store.settings
                            s.businessHoursEnabled = val
                            store.updateSettings(s)
                        }
                    ))
                }

                Section("Auto-Attendant / IVR (Dial 0)") {
                    Toggle("IVR Enabled", isOn: Binding(
                        get: { store.settings.ivrEnabled },
                        set: { val in
                            var s = store.settings
                            s.ivrEnabled = val
                            store.updateSettings(s)
                        }
                    ))
                    TextField("Company Name", text: Binding(
                        get: { store.settings.companyName },
                        set: { val in
                            var s = store.settings
                            s.companyName = val
                            store.updateSettings(s)
                        }
                    ))
                    TextField("Spoken IVR Greeting", text: Binding(
                        get: { store.settings.ivrGreeting },
                        set: { val in
                            var s = store.settings
                            s.ivrGreeting = val
                            store.updateSettings(s)
                        }
                    ), axis: .vertical)
                    ForEach(store.settings.ivrOptions) { opt in
                        LabeledContent("Press \(opt.digit)", value: "\(opt.label) → \(opt.targetExtension)")
                    }
                }

                Section("Call Queues & Ring Groups") {
                    ForEach(store.queues) { q in
                        VStack(alignment: .leading) {
                            Text("\(q.name) (Ext \(q.extensionNumber))").font(.headline)
                            Text("Members: \(q.memberExtensions.joined(separator: ", ")) • \(q.ringStrategy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets { store.deleteQueue(store.queues[idx]) }
                    }

                    VStack(spacing: 8) {
                        TextField("New Queue Name (e.g. Billing)", text: $newQueueName)
                        TextField("Queue Extension (e.g. 802)", text: $newQueueExt).keyboardType(.numberPad)
                        TextField("Member Exts comma-separated", text: $newQueueMembers)
                        Button("Add Call Queue") {
                            guard !newQueueName.isEmpty, !newQueueExt.isEmpty else { return }
                            let members = newQueueMembers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            store.addQueue(name: newQueueName, ext: newQueueExt, members: members)
                            newQueueName = ""
                            newQueueExt = ""
                        }
                    }
                }

                Section("Parked Calls (\(store.parkedCalls.count)/4)") {
                    if store.parkedCalls.isEmpty {
                        Text("No parked calls.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.parkedCalls) { p in
                            HStack {
                                Text("Slot \(p.slot): \(p.callerName) (Ext \(p.callerExtension))")
                                Spacer()
                                Button("Clear") {
                                    _ = store.unparkSlot(p.slot)
                                }
                                .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Admin Control")
            .sheet(isPresented: $showCreateUser) {
                NavigationStack {
                    Form {
                        TextField("Username", text: $newUsername).textInputAutocapitalization(.never)
                        TextField("Password", text: $newPassword).textInputAutocapitalization(.never)
                        TextField("Display Name", text: $newDisplayName)
                        TextField("Extension (blank = auto)", text: $newExt).keyboardType(.numberPad)
                        TextField("Department", text: $newDept)
                        Toggle("Admin Privileges", isOn: $newIsAdmin)
                        if let err = createError {
                            Text(err).foregroundStyle(.red).font(.caption)
                        }
                        Button("Create Account") {
                            createError = store.adminCreateAccount(
                                username: newUsername,
                                password: newPassword,
                                displayName: newDisplayName,
                                ext: newExt,
                                department: newDept,
                                isAdmin: newIsAdmin
                            )
                            if createError == nil {
                                newUsername = ""; newPassword = ""; newDisplayName = ""; newExt = ""; newDept = ""; newIsAdmin = false
                                showCreateUser = false
                            }
                        }
                    }
                    .navigationTitle("New User")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showCreateUser = false }
                        }
                    }
                }
            }
        }
    }
}

struct AdminEditUserView: View {
    @EnvironmentObject var store: PBXStore
    @Environment(\.dismiss) var dismiss
    @State var account: UserAccount

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Username", value: account.username)
                TextField("Display Name", text: $account.displayName)
                TextField("Extension", text: $account.extensionNumber).keyboardType(.numberPad)
                TextField("Department", text: $account.department)
                TextField("Password", text: $account.password).textInputAutocapitalization(.never)
            }

            Section("Permissions & Policies") {
                Toggle("Admin Role", isOn: $account.isAdmin)
                    .disabled(account.username.lowercased() == "admin")
                Toggle("Account Disabled / Banned", isOn: $account.isDisabled)
                    .disabled(account.username.lowercased() == "admin")
                Toggle("Force Auto Call Recording", isOn: $account.forceRecording)
            }

            Section {
                Button("Save Changes") {
                    store.updateAccount(account)
                    dismiss()
                }
                if account.username.lowercased() != "admin" {
                    Button("Delete Account", role: .destructive) {
                        store.deleteAccount(account)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Edit \(account.username)")
    }
}
