import Foundation
import AVFoundation
import Combine

final class VoiceAudioEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoiceAudioEngine()

    @Published var isRunning = false
    @Published var isRecording = false
    @Published var inputLevel: Float = 0
    @Published var playingFileName: String?

    var onAudioFrame: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var filePlayer: AVAudioPlayer?

    private let networkFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var isMuted = false
    private var converter: AVAudioConverter?
    private let audioLock = NSLock()
    private var recordingFile: AVAudioFile?
    private var recordingFileName: String?
    private var recordingStart: Date?

    private override init() {
        super.init()
    }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(16000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            print("[Audio] Session error: \(error.localizedDescription)")
        }
    }

    func startVoice(muted: Bool = false) {
        if isRunning { return }
        configureSession()
        isMuted = muted

        let inputNode = engine.inputNode
        try? inputNode.setVoiceProcessingEnabled(true)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[Audio] Invalid input format")
            return
        }

        converter = AVAudioConverter(from: inputFormat, to: networkFormat)

        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: networkFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processCapturedBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            playerNode.play()
            DispatchQueue.main.async {
                self.isRunning = true
            }
        } catch {
            print("[Audio] Engine start error: \(error.localizedDescription)")
        }
    }

    func stopVoice() {
        if !isRunning { return }
        stopSpeaking()
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        converter = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.inputLevel = 0
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    private func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = networkFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: outFrames) else { return }

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        guard error == nil, converted.frameLength > 0, let channelData = converted.int16ChannelData else { return }

        let sampleCount = Int(converted.frameLength)
        let samples = channelData[0]

        var peak: Int32 = 0
        if isMuted {
            for i in 0..<sampleCount { samples[i] = 0 }
        } else {
            for i in 0..<sampleCount {
                let absVal = abs(Int32(samples[i]))
                if absVal > peak { peak = absVal }
            }
        }

        let normalized = min(Float(peak) / 32768.0, 1.0)
        DispatchQueue.main.async {
            self.inputLevel = normalized
        }

        writeRecordingBuffer(converted)

        let byteCount = sampleCount * MemoryLayout<Int16>.size
        let pcmData = Data(bytes: samples, count: byteCount)
        onAudioFrame?(pcmData)
    }

    func playIncomingPCM(_ data: Data) {
        guard isRunning, data.count >= 2 else { return }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard let buffer = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { raw in
            if let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self) {
                dst.update(from: src, count: sampleCount)
            }
        }

        writeRecordingBuffer(buffer)
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func playDTMFTone(_ digit: String) {
        let freqMap: [String: (Double, Double)] = [
            "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
            "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
            "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
            "*": (941, 1209), "0": (941, 1336), "#": (941, 1477)
        ]
        guard let freqs = freqMap[digit] else { return }

        if !isRunning {
            startVoice(muted: true)
        }

        let sampleRate = 16000.0
        let count = Int(sampleRate * 0.14)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: AVAudioFrameCount(count)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)

        for i in 0..<count {
            let t = Double(i) / sampleRate
            let wave = 0.25 * (sin(2.0 * .pi * freqs.0 * t) + sin(2.0 * .pi * freqs.1 * t))
            dst[i] = Int16(max(-32767, min(32767, wave * 32767.0)))
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    func speakIVR(_ text: String) {
        stopSpeaking()
        configureSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    func recordingURL(for fileName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    func startRecording(prefix: String) -> String? {
        audioLock.lock()
        defer { audioLock.unlock() }

        let fileName = "\(prefix)_\(Int(Date().timeIntervalSince1970)).wav"
        let url = recordingURL(for: fileName)
        do {
            recordingFile = try AVAudioFile(
                forWriting: url,
                settings: networkFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            recordingFileName = fileName
            recordingStart = Date()
            DispatchQueue.main.async { self.isRecording = true }
            return fileName
        } catch {
            print("[Audio] Recording start error: \(error.localizedDescription)")
            return nil
        }
    }

    func stopRecording() -> (fileName: String, duration: TimeInterval)? {
        audioLock.lock()
        defer { audioLock.unlock() }

        guard let fileName = recordingFileName else {
            DispatchQueue.main.async { self.isRecording = false }
            return nil
        }
        let duration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingFile = nil
        recordingFileName = nil
        recordingStart = nil
        DispatchQueue.main.async { self.isRecording = false }
        return (fileName, max(1, duration))
    }

    private func writeRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
        audioLock.lock()
        defer { audioLock.unlock() }
        guard let file = recordingFile else { return }
        try? file.write(from: buffer)
    }

    func togglePlayback(fileName: String) {
        if playingFileName == fileName {
            filePlayer?.stop()
            filePlayer = nil
            playingFileName = nil
            return
        }
        filePlayer?.stop()
        let url = recordingURL(for: fileName)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            filePlayer = player
            playingFileName = fileName
        } catch {
            print("[Audio] Playback error: \(error.localizedDescription)")
            playingFileName = nil
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.playingFileName = nil
        }
    }
}
