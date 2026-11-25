import Foundation
import CallKit
import AVFoundation
import Combine

final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published var activeCall: ActiveCall?
    @Published var lastDTMF: String = ""
    @Published var statusToast: String?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var pendingQueuePeerIds: [String] = []

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 2
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.includesCallsInRecents = true

        self.provider = CXProvider(configuration: config)
        super.init()
        self.provider.setDelegate(self, queue: nil)

        VoiceAudioEngine.shared.onAudioFrame = { [weak self] pcmData in
            guard let self = self,
                  let call = self.activeCall,
                  call.state == .active,
                  let peerId = call.peerId else { return }
            MeshPBXServer.shared.sendAudioFrame(pcmData, toPeerId: peerId)
        }
    }

    func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.statusToast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.statusToast == text {
                    self.statusToast = nil
                }
            }
        }
    }

    // MARK: - Outbound Calling (Extensions, Queues, IVR, Call Park, Direct IP)

    func startCall(to rawTarget: String) {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard activeCall == nil else {
            showToast("Already on an active call.")
            return
        }

        // Direct IP:Port connect & call
        if target.contains(":") {
            let parts = target.split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]) {
                MeshPBXServer.shared.connectDirect(host: String(parts[0]), port: port)
                showToast("Connecting to \(target)...")
                return
            }
        }

        // Auto-Attendant IVR
        if target == "0" || target.lowercased() == "ivr" {
            startLocalIVRCall()
            return
        }

        // Call Park Pickup (701 - 704)
        if ["701", "702", "703", "704"].contains(target) {
            if let parked = PBXStore.shared.unparkSlot(target) {
                showToast("Picked up \(parked.callerName) from slot \(target)")
                startCall(to: parked.callerExtension)
            } else {
                showToast("Park slot \(target) is empty.")
            }
            return
        }

        // Call Queue / Ring Group
        if let queue = PBXStore.shared.queues.first(where: { $0.extensionNumber == target }) {
            let matchingPeers = MeshPBXServer.shared.peers.filter {
                queue.memberExtensions.contains($0.extensionNumber) && $0.presence != .dnd
            }
            if matchingPeers.isEmpty {
                startVoicemailDrop(forExtension: queue.extensionNumber, displayName: queue.name)
                return
            }
            let callId = UUID()
            pendingQueuePeerIds = matchingPeers.map { $0.id }
            initiateOutboundCallKit(
                callId: callId,
                peerId: matchingPeers.first?.id,
                handle: queue.extensionNumber,
                displayName: queue.name,
                queueLabel: queue.name
            )
            let me = PBXStore.shared.currentUser
            for peer in matchingPeers {
                let invite = MeshPacket(
                    type: .callInvite,
                    senderPeerId: MeshPBXServer.shared.localPeerId,
                    senderExtension: me?.extensionNumber ?? "000",
                    senderName: me?.displayName ?? "Caller",
                    callId: callId,
                    targetExtension: peer.extensionNumber,
                    queueLabel: queue.name
                )
                MeshPBXServer.shared.sendPacket(invite, toPeerId: peer.id)
            }
            return
        }

        // Direct Internal Extension via Mesh Server
        if let peer = MeshPBXServer.shared.peerForExtension(target) {
            if peer.presence == .dnd {
                startVoicemailDrop(forExtension: peer.extensionNumber, displayName: peer.displayName)
                return
            }
            let callId = UUID()
            initiateOutboundCallKit(
                callId: callId,
                peerId: peer.id,
                handle: peer.extensionNumber,
                displayName: peer.displayName,
                queueLabel: nil
            )
            let me = PBXStore.shared.currentUser
            let invite = MeshPacket(
                type: .callInvite,
                senderPeerId: MeshPBXServer.shared.localPeerId,
                senderExtension: me?.extensionNumber ?? "000",
                senderName: me?.displayName ?? "Caller",
                callId: callId,
                targetExtension: peer.extensionNumber
            )
            MeshPBXServer.shared.sendPacket(invite, toPeerId: peer.id)
            return
        }

        // Offline account -> Voicemail Box
        if let account = PBXStore.shared.accounts.first(where: { $0.extensionNumber == target }) {
            startVoicemailDrop(forExtension: account.extensionNumber, displayName: account.displayName)
            return
        }

        showToast("Extension \(target) not found on mesh.")
    }

    private func initiateOutboundCallKit(callId: UUID, peerId: String?, handle: String, displayName: String, queueLabel: String?) {
        activeCall = ActiveCall(
            id: callId,
            peerId: peerId,
            handle: handle,
            displayName: displayName,
            queueLabel: queueLabel,
            direction: .outbound,
            state: .ringing
        )
        let cxHandle = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: callId, handle: cxHandle)
        action.contactIdentifier = displayName
        requestTransaction(CXTransaction(action: action))
    }

    private func startLocalIVRCall() {
        let callId = UUID()
        activeCall = ActiveCall(
            id: callId,
            peerId: nil,
            handle: "0",
            displayName: PBXStore.shared.settings.companyName,
            queueLabel: "Auto-Attendant IVR",
            direction: .outbound,
            state: .ivr,
            connectedAt: Date()
        )
        VoiceAudioEngine.shared.startVoice(muted: false)
        VoiceAudioEngine.shared.speakIVR(PBXStore.shared.settings.ivrGreeting)
    }

    private func startVoicemailDrop(forExtension ext: String, displayName: String) {
        let callId = UUID()
        activeCall = ActiveCall(
            id: callId,
            peerId: nil,
            handle: ext,
            displayName: displayName,
            queueLabel: "Voicemail",
            direction: .outbound,
            state: .voicemail,
            connectedAt: Date(),
            isRecording: true
        )
        VoiceAudioEngine.shared.startVoice(muted: false)
        VoiceAudioEngine.shared.speakIVR("\(displayName) at extension \(ext) is unavailable. Recording your voicemail now.")
        _ = VoiceAudioEngine.shared.startRecording(prefix: "vm_\(ext)")
    }

    // MARK: - Inbound Calls

    func handleRemoteInvite(callId: UUID, peerId: String, fromExt: String, fromName: String, queueLabel: String?) {
        if PBXStore.shared.presence == .dnd || activeCall != nil || !PBXStore.shared.isWithinBusinessHours() {
            let reject = MeshPacket(type: .callReject, senderPeerId: MeshPBXServer.shared.localPeerId, callId: callId)
            MeshPBXServer.shared.sendPacket(reject, toPeerId: peerId)
            return
        }
        reportIncomingCall(uuid: callId, peerId: peerId, handle: fromExt, displayName: fromName, queueLabel: queueLabel)
    }

    func simulateLocalInboundCall() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.reportIncomingCall(
                uuid: UUID(),
                peerId: nil,
                handle: "100",
                displayName: "System Admin",
                queueLabel: "Support Queue"
            )
        }
    }

    func reportIncomingCall(
        uuid: UUID = UUID(),
        peerId: String?,
        handle: String,
        displayName: String,
        queueLabel: String? = nil,
        completion: ((Error?) -> Void)? = nil
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = queueLabel != nil ? "\(displayName) (\(queueLabel!))" : displayName
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = true

        DispatchQueue.main.async {
            self.activeCall = ActiveCall(
                id: uuid,
                peerId: peerId,
                handle: handle,
                displayName: displayName,
                queueLabel: queueLabel,
                direction: .inbound,
                state: .ringing
            )
        }

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKit] Report error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.activeCall = nil }
            }
            completion?(error)
        }
    }

    // MARK: - Remote Signaling Events

    func handleRemoteAnswer(callId: UUID, peerId: String) {
        guard var call = activeCall, call.id == callId else { return }
        call.peerId = peerId
        call.state = .active
        call.connectedAt = Date()
        activeCall = call

        // Cancel ringing on other queue agents if this was a queue call
        for otherId in pendingQueuePeerIds where otherId != peerId {
            let cancel = MeshPacket(type: .callHangup, senderPeerId: MeshPBXServer.shared.localPeerId, callId: callId)
            MeshPBXServer.shared.sendPacket(cancel, toPeerId: otherId)
        }
        pendingQueuePeerIds.removeAll()

        provider.reportOutgoingCall(with: callId, connectedAt: Date())
        VoiceAudioEngine.shared.startVoice(muted: call.isMuted)
        maybeStartAutoRecording()
    }

    func handleRemoteHangup(callId: UUID) {
        guard let call = activeCall, call.id == callId else { return }
        provider.reportCall(with: callId, endedAt: Date(), reason: .remoteEnded)
        cleanupCall()
    }

    func handleRemoteHold(callId: UUID, isHeld: Bool) {
        guard var call = activeCall, call.id == callId else { return }
        call.isHeld = isHeld
        call.state = isHeld ? .held : .active
        activeCall = call
    }

    func handleRemoteTransfer(targetExt: String) {
        showToast("Call transferred to ext \(targetExt)")
        endActiveCall()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.startCall(to: targetExt)
        }
    }

    func handleRemoteDTMF(digit: String) {
        lastDTMF += digit
        VoiceAudioEngine.shared.playDTMFTone(digit)
    }

    // MARK: - In-Call Controls

    func endActiveCall() {
        guard let call = activeCall else { return }
        if let peerId = call.peerId {
            let packet = MeshPacket(type: .callHangup, senderPeerId: MeshPBXServer.shared.localPeerId, callId: call.id)
            MeshPBXServer.shared.sendPacket(packet, toPeerId: peerId)
        }
        if call.state == .ivr || call.state == .voicemail {
            cleanupCall()
            return
        }
        requestTransaction(CXTransaction(action: CXEndCallAction(call: call.id)))
    }

    func toggleMute() {
        guard var call = activeCall else { return }
        if call.state == .ivr || call.state == .voicemail {
            call.isMuted.toggle()
            activeCall = call
            VoiceAudioEngine.shared.setMuted(call.isMuted)
            return
        }
        requestTransaction(CXTransaction(action: CXSetMutedCallAction(call: call.id, muted: !call.isMuted)))
    }

    func toggleHold() {
        guard let call = activeCall, call.state == .active || call.state == .held else { return }
        requestTransaction(CXTransaction(action: CXSetHeldCallAction(call: call.id, onHold: !call.isHeld)))
    }

    func toggleSpeaker() {
        guard var call = activeCall else { return }
        let newState = !call.isSpeakerOn
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(newState ? .speaker : .none)
            call.isSpeakerOn = newState
            activeCall = call
        } catch {
            print("[Audio] Speaker toggle error: \(error.localizedDescription)")
        }
    }

    func toggleRecording() {
        guard var call = activeCall else { return }
        if call.isRecording {
            if let result = VoiceAudioEngine.shared.stopRecording() {
                saveRecordingEntry(fileName: result.fileName, duration: result.duration, call: call, kind: "Call Recording")
                showToast("Recording saved.")
            }
            call.isRecording = false
            activeCall = call
        } else {
            if VoiceAudioEngine.shared.startRecording(prefix: "rec_\(call.handle)") != nil {
                call.isRecording = true
                activeCall = call
                showToast("Call recording started.")
            }
        }
    }

    func sendDTMF(_ digit: String) {
        guard let call = activeCall else { return }
        lastDTMF += digit
        VoiceAudioEngine.shared.playDTMFTone(digit)

        if call.state == .ivr {
            VoiceAudioEngine.shared.stopSpeaking()
            if let option = PBXStore.shared.settings.ivrOptions.first(where: { $0.digit == digit }) {
                cleanupCall()
                if option.targetExtension == "VM" {
                    startVoicemailDrop(forExtension: "100", displayName: "General Voicemail")
                } else {
                    startCall(to: option.targetExtension)
                }
            }
            return
        }

        if let peerId = call.peerId {
            let packet = MeshPacket(type: .dtmf, senderPeerId: MeshPBXServer.shared.localPeerId, callId: call.id, textValue: digit)
            MeshPBXServer.shared.sendPacket(packet, toPeerId: peerId)
        }
        requestTransaction(CXTransaction(action: CXPlayDTMFCallAction(call: call.id, digits: digit, type: .singleTone)))
    }

    func blindTransfer(to targetExt: String) {
        guard let call = activeCall, let peerId = call.peerId else {
            showToast("Transfer requires an active peer call.")
            return
        }
        let packet = MeshPacket(
            type: .callTransfer,
            senderPeerId: MeshPBXServer.shared.localPeerId,
            callId: call.id,
            targetExtension: targetExt
        )
        MeshPBXServer.shared.sendPacket(packet, toPeerId: peerId)
        showToast("Transferred to ext \(targetExt)")
        endActiveCall()
    }

    func parkActiveCall() -> String? {
        guard let call = activeCall else { return nil }
        let myExt = PBXStore.shared.currentUser?.extensionNumber ?? "100"
        guard let slot = PBXStore.shared.parkCall(callerName: call.displayName, callerExt: call.handle, byExt: myExt) else {
            showToast("All park slots (701–704) are full.")
            return nil
        }
        showToast("Call parked on slot \(slot)")
        endActiveCall()
        return slot
    }

    func updateNotes(_ notes: String) {
        activeCall?.notes = notes
    }

    private func maybeStartAutoRecording() {
        guard var call = activeCall, !call.isRecording else { return }
        let shouldRecord = PBXStore.shared.settings.globalRecording || (PBXStore.shared.currentUser?.forceRecording ?? false)
        if shouldRecord {
            if VoiceAudioEngine.shared.startRecording(prefix: "auto_\(call.handle)") != nil {
                call.isRecording = true
                activeCall = call
            }
        }
    }

    private func saveRecordingEntry(fileName: String, duration: TimeInterval, call: ActiveCall, kind: String) {
        let rec = VoicemailRecording(
            id: UUID(),
            title: "\(kind): \(call.displayName)",
            fromExtension: call.handle,
            fromName: call.displayName,
            kind: kind,
            fileName: fileName,
            duration: duration,
            timestamp: Date(),
            isRead: kind == "Call Recording"
        )
        PBXStore.shared.addRecording(rec)
    }

    private func cleanupCall() {
        guard let call = activeCall else { return }
        if call.isRecording, let result = VoiceAudioEngine.shared.stopRecording() {
            let kind = call.state == .voicemail ? "Voicemail" : "Call Recording"
            saveRecordingEntry(fileName: result.fileName, duration: result.duration, call: call, kind: kind)
        }
        VoiceAudioEngine.shared.stopVoice()

        let duration = call.connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        let entry = CallLogEntry(
            id: call.id,
            handle: call.handle,
            displayName: call.displayName,
            queueLabel: call.queueLabel,
            direction: call.direction,
            timestamp: Date(),
            duration: duration,
            wasAnswered: call.connectedAt != nil,
            notes: call.notes
        )
        PBXStore.shared.addCallLog(entry)
        activeCall = nil
        lastDTMF = ""
        pendingQueuePeerIds.removeAll()
    }

    private func requestTransaction(_ transaction: CXTransaction) {
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKit] Transaction error: \(error.localizedDescription)")
            }
        }
    }
}

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        cleanupCall()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        VoiceAudioEngine.shared.configureSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        activeCall?.state = .connecting
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        VoiceAudioEngine.shared.configureSession()
        activeCall?.state = .active
        activeCall?.connectedAt = Date()

        if let peerId = activeCall?.peerId {
            let packet = MeshPacket(
                type: .callAnswer,
                senderPeerId: MeshPBXServer.shared.localPeerId,
                senderExtension: PBXStore.shared.currentUser?.extensionNumber,
                callId: action.callUUID
            )
            MeshPBXServer.shared.sendPacket(packet, toPeerId: peerId)
        }
        VoiceAudioEngine.shared.startVoice(muted: activeCall?.isMuted ?? false)
        maybeStartAutoRecording()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let peerId = activeCall?.peerId {
            let packet = MeshPacket(type: .callHangup, senderPeerId: MeshPBXServer.shared.localPeerId, callId: action.callUUID)
            MeshPBXServer.shared.sendPacket(packet, toPeerId: peerId)
        }
        cleanupCall()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        activeCall?.isHeld = action.isOnHold
        activeCall?.state = action.isOnHold ? .held : .active
        VoiceAudioEngine.shared.setMuted(action.isOnHold || (activeCall?.isMuted ?? false))
        if let peerId = activeCall?.peerId {
            let packet = MeshPacket(type: .callHold, senderPeerId: MeshPBXServer.shared.localPeerId, callId: action.callUUID, boolValue: action.isOnHold)
            MeshPBXServer.shared.sendPacket(packet, toPeerId: peerId)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        activeCall?.isMuted = action.isMuted
        VoiceAudioEngine.shared.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        if let call = activeCall, call.state == .active {
            VoiceAudioEngine.shared.startVoice(muted: call.isMuted)
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        VoiceAudioEngine.shared.stopVoice()
    }
}
