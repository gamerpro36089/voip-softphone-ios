import Foundation
import Network
import Darwin
import Combine

final class MeshPBXServer: ObservableObject {
    static let shared = MeshPBXServer()

    @Published var isListening = false
    @Published var listenPort: UInt16 = 0
    @Published var localIPs: [(name: String, ip: String)] = []
    @Published var peers: [DiscoveredPeer] = []
    @Published var statusMessage: String = "Server Idle"

    let localPeerId: String
    private let serviceType = "_voippbx._tcp"
    private let netQueue = DispatchQueue(label: "com.local.meshpbx.network")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var endpointMap: [String: NWEndpoint] = [:]

    private init() {
        let key = "meshpbx_peer_id"
        if let saved = UserDefaults.standard.string(forKey: key) {
            self.localPeerId = saved
        } else {
            let fresh = String(UUID().uuidString.prefix(8))
            UserDefaults.standard.set(fresh, forKey: key)
            self.localPeerId = fresh
        }
        refreshLocalIPs()
    }

    func refreshLocalIPs() {
        var results: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let current = ptr {
                let interface = current.pointee
                if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name.hasPrefix("utun") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if !ip.hasPrefix("127.") {
                                results.append((name, ip))
                            }
                        }
                    }
                }
                ptr = interface.ifa_next
            }
        }
        DispatchQueue.main.async {
            self.localIPs = results
        }
    }

    func startServer() {
        guard let user = PBXStore.shared.currentUser else { return }
        stopServer()
        refreshLocalIPs()

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        do {
            let newListener = try NWListener(using: params)
            let serviceName = "ext\(user.extensionNumber)-\(localPeerId)"
            newListener.service = NWListener.Service(name: serviceName, type: serviceType)

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.listenPort = newListener.port?.rawValue ?? 0
                        self.statusMessage = "Running on port \(self.listenPort)"
                        self.refreshLocalIPs()
                    case .failed(let err):
                        self.isListening = false
                        self.statusMessage = "Failed: \(err.localizedDescription)"
                    case .cancelled:
                        self.isListening = false
                        self.statusMessage = "Stopped"
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] conn in
                let tempId = "in-\(UUID().uuidString.prefix(6))"
                self?.setupConnection(conn, initialPeerId: tempId, hostLabel: "\(conn.endpoint)")
            }

            newListener.start(queue: netQueue)
            self.listener = newListener
            startBrowsing(params: params)
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Listener error: \(error.localizedDescription)"
            }
        }
    }

    func restartServer() {
        stopServer()
        startServer()
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        endpointMap.removeAll()
        DispatchQueue.main.async {
            self.isListening = false
            self.listenPort = 0
            self.peers.removeAll()
            self.statusMessage = "Stopped"
        }
    }

    private func startBrowsing(params: NWParameters) {
        let newBrowser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    if name.hasSuffix("-\(self.localPeerId)") { continue }
                    let peerKey = name
                    if self.connections[peerKey] == nil {
                        self.endpointMap[peerKey] = result.endpoint
                        let conn = NWConnection(to: result.endpoint, using: params)
                        self.setupConnection(conn, initialPeerId: peerKey, hostLabel: "Bonjour LAN")
                    }
                }
            }
        }
        newBrowser.start(queue: netQueue)
        self.browser = newBrowser
    }

    func connectDirect(host: String, port: UInt16) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(cleanHost), port: nwPort)
        let key = "ip-\(cleanHost):\(port)"
        let conn = NWConnection(to: endpoint, using: params)
        setupConnection(conn, initialPeerId: key, hostLabel: "\(cleanHost):\(port)")
    }

    private func setupConnection(_ conn: NWConnection, initialPeerId: String, hostLabel: String) {
        connections[initialPeerId] = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendHello(on: conn)
                self.sendSyncState(on: conn)
                self.receiveHeader(on: conn, connKey: initialPeerId, hostLabel: hostLabel)
            case .failed, .cancelled:
                self.removeConnection(key: initialPeerId)
            default:
                break
            }
        }

        conn.start(queue: netQueue)
    }

    private func removeConnection(key: String) {
        netQueue.async {
            self.connections.removeValue(forKey: key)
            DispatchQueue.main.async {
                self.peers.removeAll { $0.id == key }
            }
        }
    }

    private func receiveHeader(on conn: NWConnection, connKey: String, hostLabel: String) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || (isComplete && (data == nil || data?.isEmpty == true)) {
                self.removeConnection(key: connKey)
                return
            }
            guard let headerData = data, headerData.count == 5 else {
                self.removeConnection(key: connKey)
                return
            }
            let bytes = [UInt8](headerData)
            let frameType = bytes[0]
            let length = (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 8) | UInt32(bytes[4])
            guard length > 0, length < 2_000_000 else {
                self.removeConnection(key: connKey)
                return
            }
            self.receiveBody(on: conn, connKey: connKey, hostLabel: hostLabel, frameType: frameType, length: Int(length))
        }
    }

    private func receiveBody(on conn: NWConnection, connKey: String, hostLabel: String, frameType: UInt8, length: Int) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil {
                self.removeConnection(key: connKey)
                return
            }
            if let payload = data {
                if frameType == 2 {
                    VoiceAudioEngine.shared.playIncomingPCM(payload)
                } else if frameType == 1, let packet = try? JSONDecoder().decode(MeshPacket.self, from: payload) {
                    self.handleIncomingPacket(packet, conn: conn, connKey: connKey, hostLabel: hostLabel)
                }
            }
            self.receiveHeader(on: conn, connKey: connKey, hostLabel: hostLabel)
        }
    }

    private func sendFrame(type: UInt8, payload: Data, on conn: NWConnection) {
        var packet = Data(capacity: 5 + payload.count)
        packet.append(type)
        let len = UInt32(payload.count)
        packet.append(UInt8((len >> 24) & 0xFF))
        packet.append(UInt8((len >> 16) & 0xFF))
        packet.append(UInt8((len >> 8) & 0xFF))
        packet.append(UInt8(len & 0xFF))
        packet.append(payload)
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    func sendPacket(_ packet: MeshPacket, toPeerId peerId: String) {
        guard let data = try? JSONEncoder().encode(packet) else { return }
        netQueue.async {
            if let conn = self.connections[peerId] {
                self.sendFrame(type: 1, payload: data, on: conn)
            }
        }
    }

    func broadcastPacket(_ packet: MeshPacket) {
        guard let data = try? JSONEncoder().encode(packet) else { return }
        netQueue.async {
            for (_, conn) in self.connections {
                self.sendFrame(type: 1, payload: data, on: conn)
            }
        }
    }

    func sendAudioFrame(_ pcmData: Data, toPeerId peerId: String) {
        netQueue.async {
            if let conn = self.connections[peerId] {
                self.sendFrame(type: 2, payload: pcmData, on: conn)
            }
        }
    }

    private func sendHello(on conn: NWConnection) {
        let user = PBXStore.shared.currentUser
        let packet = MeshPacket(
            type: .hello,
            senderPeerId: localPeerId,
            senderExtension: user?.extensionNumber ?? "000",
            senderName: user?.displayName ?? "Unknown",
            presence: PBXStore.shared.presence
        )
        if let data = try? JSONEncoder().encode(packet) {
            sendFrame(type: 1, payload: data, on: conn)
        }
    }

    func broadcastHello() {
        let user = PBXStore.shared.currentUser
        let packet = MeshPacket(
            type: .hello,
            senderPeerId: localPeerId,
            senderExtension: user?.extensionNumber ?? "000",
            senderName: user?.displayName ?? "Unknown",
            presence: PBXStore.shared.presence
        )
        broadcastPacket(packet)
    }

    private func sendSyncState(on conn: NWConnection) {
        let store = PBXStore.shared
        let packet = MeshPacket(
            type: .syncState,
            senderPeerId: localPeerId,
            accounts: store.accounts,
            settings: store.settings,
            queues: store.queues,
            parkedCalls: store.parkedCalls
        )
        if let data = try? JSONEncoder().encode(packet) {
            sendFrame(type: 1, payload: data, on: conn)
        }
    }

    func broadcastSyncState() {
        let store = PBXStore.shared
        let packet = MeshPacket(
            type: .syncState,
            senderPeerId: localPeerId,
            accounts: store.accounts,
            settings: store.settings,
            queues: store.queues,
            parkedCalls: store.parkedCalls
        )
        broadcastPacket(packet)
    }

    func sendChat(toExtension: String, body: String) {
        guard let user = PBXStore.shared.currentUser else { return }
        let msg = ChatMessage(
            id: UUID(),
            fromExtension: user.extensionNumber,
            fromName: user.displayName,
            toExtension: toExtension,
            body: body,
            timestamp: Date()
        )
        PBXStore.shared.addMessage(msg)
        let packet = MeshPacket(
            type: .chat,
            senderPeerId: localPeerId,
            senderExtension: user.extensionNumber,
            senderName: user.displayName,
            chatMessage: msg
        )
        broadcastPacket(packet)
    }

    func sendAdminCommand(_ command: String, targetExtension: String?, note: String? = nil) {
        let packet = MeshPacket(
            type: .adminCommand,
            senderPeerId: localPeerId,
            targetExtension: targetExtension,
            textValue: "\(command)|\(note ?? "")"
        )
        broadcastPacket(packet)
    }

    func sendBroadcastAlert(_ message: String) {
        DispatchQueue.main.async {
            PBXStore.shared.broadcastBanner = message
        }
        let packet = MeshPacket(
            type: .broadcast,
            senderPeerId: localPeerId,
            textValue: message
        )
        broadcastPacket(packet)
    }

    func peerForExtension(_ ext: String) -> DiscoveredPeer? {
        peers.first { $0.extensionNumber == ext && $0.isConnected }
    }

    private func handleIncomingPacket(_ packet: MeshPacket, conn: NWConnection, connKey: String, hostLabel: String) {
        if packet.senderPeerId == localPeerId { return }

        let mappedKey = packet.senderPeerId
        if mappedKey != connKey {
            connections[mappedKey] = conn
            connections.removeValue(forKey: connKey)
        }

        DispatchQueue.main.async {
            switch packet.type {
            case .hello:
                let ext = packet.senderExtension ?? "---"
                let name = packet.senderName ?? "Peer"
                let presence = packet.presence ?? .available
                let peer = DiscoveredPeer(
                    id: mappedKey,
                    name: name,
                    extensionNumber: ext,
                    displayName: name,
                    presence: presence,
                    hostInfo: hostLabel,
                    isConnected: true
                )
                if let idx = self.peers.firstIndex(where: { $0.id == mappedKey }) {
                    self.peers[idx] = peer
                } else {
                    self.peers.append(peer)
                }

            case .syncState:
                PBXStore.shared.mergeSync(
                    accounts: packet.accounts,
                    settings: packet.settings,
                    queues: packet.queues,
                    parkedCalls: packet.parkedCalls
                )

            case .callInvite:
                guard let callId = packet.callId else { return }
                let fromExt = packet.senderExtension ?? "Unknown"
                let fromName = packet.senderName ?? fromExt
                CallManager.shared.handleRemoteInvite(
                    callId: callId,
                    peerId: mappedKey,
                    fromExt: fromExt,
                    fromName: fromName,
                    queueLabel: packet.queueLabel
                )

            case .callAnswer:
                if let callId = packet.callId {
                    CallManager.shared.handleRemoteAnswer(callId: callId, peerId: mappedKey)
                }

            case .callReject, .callHangup:
                if let callId = packet.callId {
                    CallManager.shared.handleRemoteHangup(callId: callId)
                }

            case .callHold:
                if let callId = packet.callId {
                    CallManager.shared.handleRemoteHold(callId: callId, isHeld: packet.boolValue ?? false)
                }

            case .callTransfer:
                if let target = packet.targetExtension {
                    CallManager.shared.handleRemoteTransfer(targetExt: target)
                }

            case .dtmf:
                if let digit = packet.textValue {
                    CallManager.shared.handleRemoteDTMF(digit: digit)
                }

            case .chat:
                if let msg = packet.chatMessage {
                    PBXStore.shared.addMessage(msg)
                }

            case .broadcast:
                PBXStore.shared.broadcastBanner = packet.textValue

            case .adminCommand:
                let myExt = PBXStore.shared.currentUser?.extensionNumber
                if packet.targetExtension == nil || packet.targetExtension == myExt {
                    let parts = (packet.textValue ?? "").split(separator: "|", maxSplits: 1).map(String.init)
                    let cmd = parts.first ?? ""
                    if cmd == "forceHangup" {
                        CallManager.shared.endActiveCall()
                    } else if cmd == "forceSignOut" {
                        CallManager.shared.endActiveCall()
                        PBXStore.shared.signOut()
                    }
                }

            default:
                break
            }
        }
    }
}
