import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = CallManager.shared
        VoIPPushManager.shared.start()
        return true
    }
}

@main
struct VoIPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var callManager = CallManager.shared
    @StateObject private var pushManager = VoIPPushManager.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(callManager)
                .environmentObject(pushManager)
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            TabView {
                InboundDashboardView()
                    .tabItem { Label("Line", systemImage: "phone.arrow.down.left") }

                RecentsView()
                    .tabItem { Label("Recents", systemImage: "clock") }

                OutboundPlaceholderView()
                    .tabItem { Label("Keypad", systemImage: "circle.grid.3x3") }
            }

            if let call = callManager.activeCall, call.state != .ringing {
                InCallHUDView(call: call)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: callManager.activeCall?.state)
    }
}

struct InboundDashboardView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var pushManager: VoIPPushManager

    var body: some View {
        NavigationStack {
            List {
                Section("Inbound Line Status") {
                    LabeledContent("Mode", value: "Inbound Only (Phase 1)")
                    LabeledContent("PushKit") {
                        Text(pushManager.voipPushTokenHex)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section("Test CallKit Locally") {
                    Button {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            callManager.reportIncomingCall(
                                handle: "+15550199",
                                displayName: "Main Office",
                                queueLabel: "Support Queue"
                            )
                        }
                    } label: {
                        Label("Simulate Inbound Call (3s Delay)", systemImage: "bell.badge")
                    }
                }
            }
            .navigationTitle("Softphone")
        }
    }
}

struct InCallHUDView: View {
    @EnvironmentObject var callManager: CallManager
    let call: ActiveCall
    @State private var showKeypad = false

    var body: some View {
        VStack(spacing: 24) {
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
                Text(call.handle).font(.subheadline).foregroundStyle(.secondary)
                Text(call.state.rawValue)
                    .font(.headline)
                    .foregroundStyle(call.isHeld ? .orange : .green)
            }

            if showKeypad {
                DTMFPadView { digit in callManager.sendDTMF(digit) }
            }

            HStack(spacing: 28) {
                CallActionButton(
                    icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: "Mute",
                    active: call.isMuted
                ) { callManager.toggleMute() }

                CallActionButton(
                    icon: "circle.grid.3x3.fill",
                    label: "Keypad",
                    active: showKeypad
                ) { showKeypad.toggle() }

                CallActionButton(
                    icon: "speaker.wave.3.fill",
                    label: "Speaker",
                    active: call.isSpeakerOn
                ) { callManager.toggleSpeaker() }

                CallActionButton(
                    icon: "pause.fill",
                    label: "Hold",
                    active: call.isHeld
                ) { callManager.toggleHold() }
            }

            Button(role: .destructive) {
                callManager.endActiveCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(.top, 12)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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
                    .frame(width: 58, height: 58)
                    .background(active ? Color.white : Color.secondary.opacity(0.2), in: Circle())
                    .foregroundStyle(active ? Color.black : Color.primary)
                Text(label).font(.caption)
            }
        }
    }
}

struct DTMFPadView: View {
    let onTap: (String) -> Void
    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            ForEach(keys, id: \.self) { key in
                Button { onTap(key) } label: {
                    Text(key)
                        .font(.title2.bold())
                        .frame(width: 60, height: 48)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: 230)
    }
}

struct RecentsView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        NavigationStack {
            List(callManager.callHistory) { entry in
                HStack {
                    Image(systemName: entry.wasAnswered ? "phone.arrow.down.left" : "phone.down.left")
                        .foregroundStyle(entry.wasAnswered ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(entry.displayName).font(.headline)
                        Text(entry.handle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(entry.duration))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Recents")
        }
    }
}

struct OutboundPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.arrow.up.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Outbound Dialing (Phase 2)")
                .font(.title3.bold())
            Text("Inbound CallKit is active. Outbound dialing will plug into CXStartCallAction next.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
