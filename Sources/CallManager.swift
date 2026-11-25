import Foundation
import CallKit
import AVFoundation
import Combine

final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published var activeCall: ActiveCall?
    @Published var callHistory: [CallLogEntry] = []
    @Published var lastDTMF: String = ""

    private let provider: CXProvider
    private let callController = CXCallController()

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
    }

    func reportIncomingCall(
        uuid: UUID = UUID(),
        handle: String,
        displayName: String,
        queueLabel: String? = nil,
        completion: ((Error?) -> Void)? = nil
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)
        update.localizedCallerName = queueLabel != nil ? "\(displayName) (\(queueLabel!))" : displayName
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = true
        update.supportsDTMF = true

        DispatchQueue.main.async {
            self.activeCall = ActiveCall(
                id: uuid,
                handle: handle,
                displayName: displayName,
                queueLabel: queueLabel,
                direction: .inbound,
                state: .ringing
            )
        }

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKit] Error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.activeCall = nil }
            }
            completion?(error)
        }
    }

    func endActiveCall() {
        guard let call = activeCall else { return }
        requestTransaction(CXTransaction(action: CXEndCallAction(call: call.id)))
    }

    func toggleMute() {
        guard let call = activeCall else { return }
        requestTransaction(CXTransaction(action: CXSetMutedCallAction(call: call.id, muted: !call.isMuted)))
    }

    func toggleHold() {
        guard let call = activeCall else { return }
        requestTransaction(CXTransaction(action: CXSetHeldCallAction(call: call.id, onHold: !call.isHeld)))
    }

    func sendDTMF(_ digit: String) {
        guard let call = activeCall else { return }
        requestTransaction(CXTransaction(action: CXPlayDTMFCallAction(call: call.id, digits: digit, type: .singleTone)))
    }

    func toggleSpeaker() {
        guard var call = activeCall else { return }
        let newState = !call.isSpeakerOn
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(newState ? .speaker : .none)
            call.isSpeakerOn = newState
            activeCall = call
        } catch {
            print("[Audio] Speaker error: \(error.localizedDescription)")
        }
    }

    private func requestTransaction(_ transaction: CXTransaction) {
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKit] Transaction error: \(error.localizedDescription)")
            }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.005)
        } catch {
            print("[Audio] Config error: \(error.localizedDescription)")
        }
    }

    private func archiveAndClearCall() {
        guard let call = activeCall else { return }
        let duration = call.connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        let entry = CallLogEntry(
            id: call.id,
            handle: call.handle,
            displayName: call.displayName,
            queueLabel: call.queueLabel,
            direction: call.direction,
            timestamp: Date(),
            duration: duration,
            wasAnswered: call.connectedAt != nil
        )
        callHistory.insert(entry, at: 0)
        activeCall = nil
        lastDTMF = ""
    }
}

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        archiveAndClearCall()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()
        activeCall?.state = .connecting
        activeCall?.connectedAt = Date()
        activeCall?.state = .active
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        archiveAndClearCall()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        activeCall?.isHeld = action.isOnHold
        activeCall?.state = action.isOnHold ? .held : .active
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        activeCall?.isMuted = action.isMuted
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        lastDTMF += action.digits
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
