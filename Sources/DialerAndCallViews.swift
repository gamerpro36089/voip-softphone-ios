import SwiftUI

struct DialerView: View {
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var server: MeshPBXServer
    @EnvironmentObject var callManager: CallManager

    @State private var dialText = ""
    @State private var showDirectIPSheet = false
    @State private var directHost = ""
    @State private var directPort = ""

    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let banner = store.broadcastBanner, !banner.isEmpty {
                        HStack {
                            Image(systemName: "megaphone.fill").foregroundStyle(.orange)
                            Text(banner).font(.footnote.bold())
                            Spacer()
                            Button { store.broadcastBanner = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                    }

                    // Status & Presence Strip
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(store.currentUser?.displayName ?? "") • Ext \(store.currentUser?.extensionNumber ?? "")")
                                .font(.subheadline.bold())
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(server.isListening ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(server.isListening ? "Server Port \(server.listenPort) • \(server.peers.count) online" : "Server Off")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach(PresenceStatus.allCases) { st in
                                Button(st.rawValue) {
                                    store.presence = st
                                    server.broadcastHello()
                                }
                            }
                        } label: {
                            Text(store.presence.rawValue)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(presenceColor(store.presence).opacity(0.2), in: Capsule())
                                .foregroundStyle(presenceColor(store.presence))
                        }
                    }
                    .padding(.horizontal)

                    // Dial Display
                    HStack {
                        Text(dialText.isEmpty ? "Enter Ext (e.g. 100, 0, 800)" : dialText)
                            .font(dialText.isEmpty ? .subheadline : .largeTitle.monospacedDigit().bold())
                            .foregroundStyle(dialText.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        if !dialText.isEmpty {
                            Button {
                                dialText.removeLast()
                            } label: {
                                Image(systemName: "delete.left.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: 44)
                    .padding(.horizontal)

                    // Numeric Keypad
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                        ForEach(keys, id: \.self) { key in
                            Button {
                                dialText += key
                                VoiceAudioEngine.shared.playDTMFTone(key)
                            } label: {
                                Text(key)
                                    .font(.title.bold())
                                    .frame(width: 72, height: 60)
                                    .background(Color.secondary.opacity(0.14), in: Circle())
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .frame(maxWidth: 260)

                    // Primary Call Button
                    HStack(spacing: 24) {
                        Button {
                            showDirectIPSheet = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "network").font(.title3)
                                Text("Add IP").font(.caption2)
                            }
                            .frame(width: 58, height: 58)
                            .background(Color.secondary.opacity(0.14), in: Circle())
                        }

                        Button {
                            guard !dialText.isEmpty else { return }
                            callManager.startCall(to: dialText)
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.title)
                                .frame(width: 68, height: 68)
                                .background(Color.green, in: Circle())
                                .foregroundStyle(.white)
                        }

                        Button {
                            callManager.simulateLocalInboundCall()
                            callManager.showToast("Lock screen now: ringing in 3s")
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "bell.badge").font(.title3)
                                Text("Test 3s").font(.caption2)
                            }
                            .frame(width: 58, height: 58)
                            .background(Color.secondary.opacity(0.14), in: Circle())
                        }
                    }

                    // Quick PBX Shortcuts
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            QuickDialChip(title: "0 • IVR") { callManager.startCall(to: "0") }
                            ForEach(store.queues) { q in
                                QuickDialChip(title: "\(q.extensionNumber) • \(q.name)") {
                                    callManager.startCall(to: q.extensionNumber)
                                }
                            }
                            ForEach(store.parkedCalls) { parked in
                                QuickDialChip(title: "Park \(parked.slot): \(parked.callerName)") {
                                    callManager.startCall(to: parked.slot)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Online Mesh Peers
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Online Phones on Mesh (\(server.peers.count))")
                            .font(.headline)
                            .padding(.horizontal)

                        if server.peers.isEmpty {
                            Text("Open this app on another iPhone on the same Wi-Fi (or tap Add IP over VPN/Tailscale) to call directly.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        } else {
                            ForEach(server.peers) { peer in
                                HStack {
                                    Circle()
                                        .fill(presenceColor(peer.presence))
                                        .frame(width: 10, height: 10)
                                    VStack(alignment: .leading) {
                                        Text("\(peer.displayName) (Ext \(peer.extensionNumber))")
                                            .font(.subheadline.bold())
                                        Text("\(peer.presence.rawValue) • \(peer.hostInfo)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        callManager.startCall(to: peer.extensionNumber)
                                    } label: {
                                        Image(systemName: "phone.fill")
                                            .padding(10)
                                            .background(Color.green.opacity(0.2), in: Circle())
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical)
            }
            .navigationTitle("Keypad")
            .sheet(isPresented: $showDirectIPSheet) {
                NavigationStack {
                    Form {
                        Section("Connect to Remote Phone Server") {
                            TextField("IP Address (e.g. 192.168.1.25 or 100.x.x.x)", text: $directHost)
                                .keyboardType(.numbersAndPunctuation)
                            TextField("Port (shown on other phone)", text: $directPort)
                                .keyboardType(.numberPad)
                        }
                        Section("Your Phone's Server Address") {
                            ForEach(server.localIPs, id: \.ip) { item in
                                LabeledContent(item.name, value: "\(item.ip):\(server.listenPort)")
                            }
                        }
                        Button("Connect Peer") {
                            if let p = UInt16(directPort) {
                                server.connectDirect(host: directHost, port: p)
                                showDirectIPSheet = false
                            }
                        }
                    }
                    .navigationTitle("Direct Peer IP")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showDirectIPSheet = false }
                        }
                    }
                }
            }
        }
    }

    private func presenceColor(_ status: PresenceStatus) -> Color {
        switch status {
        case .available: return .green
        case .busy: return .orange
        case .dnd: return .red
        case .away: return .gray
        }
    }
}

struct QuickDialChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.14), in: Capsule())
                .foregroundStyle(.blue)
        }
    }
}

struct InCallHUDView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var server: MeshPBXServer
    @ObservedObject private var audio = VoiceAudioEngine.shared

    let call: ActiveCall
    @State private var showKeypad = false
    @State private var showTransferSheet = false
    @State private var showNotesSheet = false
    @State private var notesDraft = ""
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 6) {
                if let queue = call.queueLabel {
                    Text(queue.uppercased())
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Text(call.displayName).font(.largeTitle.bold())
                Text("Ext \(call.handle)").font(.subheadline).foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(call.state.rawValue)
                        .font(.headline)
                        .foregroundStyle(call.isHeld ? .orange : .green)
                    if let start = call.connectedAt {
                        Text(formatDuration(now.timeIntervalSince(start)))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if call.isRecording {
                    Label("RECORDING", systemImage: "record.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }

                ProgressView(value: Double(audio.inputLevel))
                    .frame(width: 140)
                    .tint(.green)
            }

            if showKeypad || call.state == .ivr {
                DTMFPadView { digit in callManager.sendDTMF(digit) }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                CallActionButton(icon: call.isMuted ? "mic.slash.fill" : "mic.fill", label: "Mute", active: call.isMuted) {
                    callManager.toggleMute()
                }
                CallActionButton(icon: "circle.grid.3x3.fill", label: "Keypad", active: showKeypad) {
                    showKeypad.toggle()
                }
                CallActionButton(icon: "speaker.wave.3.fill", label: "Speaker", active: call.isSpeakerOn) {
                    callManager.toggleSpeaker()
                }
                CallActionButton(icon: "pause.fill", label: "Hold", active: call.isHeld) {
                    callManager.toggleHold()
                }
                CallActionButton(icon: "record.circle", label: "Record", active: call.isRecording) {
                    callManager.toggleRecording()
                }
                CallActionButton(icon: "arrow.triangle.turn.up.right.circle", label: "Transfer", active: false) {
                    showTransferSheet = true
                }
                CallActionButton(icon: "parkingsign.circle", label: "Park", active: false) {
                    _ = callManager.parkActiveCall()
                }
                CallActionButton(icon: "note.text", label: "Notes", active: !call.notes.isEmpty) {
                    notesDraft = call.notes
                    showNotesSheet = true
                }
                CallActionButton(icon: "waveform", label: "DTMF: \(callManager.lastDTMF.suffix(4))", active: false) {}
            }
            .frame(maxWidth: 300)

            Button(role: .destructive) {
                callManager.endActiveCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onReceive(timer) { tick in now = tick }
        .sheet(isPresented: $showTransferSheet) {
            NavigationStack {
                List {
                    Section("Transfer Call To Extension") {
                        ForEach(store.accounts) { acct in
                            Button("\(acct.displayName) (Ext \(acct.extensionNumber))") {
                                showTransferSheet = false
                                callManager.blindTransfer(to: acct.extensionNumber)
                            }
                        }
                    }
                }
                .navigationTitle("Blind Transfer")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTransferSheet = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showNotesSheet) {
            NavigationStack {
                Form {
                    TextEditor(text: $notesDraft).frame(minHeight: 160)
                }
                .navigationTitle("Call Notes")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            callManager.updateNotes(notesDraft)
                            showNotesSheet = false
                        }
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct CallActionButton: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(active ? Color.blue : Color.secondary.opacity(0.18), in: Circle())
                    .foregroundStyle(active ? Color.white : Color.primary)
                Text(label).font(.caption2).lineLimit(1)
            }
        }
    }
}

struct DTMFPadView: View {
    let onTap: (String) -> Void
    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
            ForEach(keys, id: \.self) { key in
                Button { onTap(key) } label: {
                    Text(key)
                        .font(.title2.bold())
                        .frame(width: 58, height: 42)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: 220)
    }
}
