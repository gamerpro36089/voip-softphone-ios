import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = CallManager.shared
        if PBXStore.shared.currentUser != nil {
            MeshPBXServer.shared.startServer()
        }
        return true
    }
}

@main
struct VoIPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PBXStore.shared
    @StateObject private var server = MeshPBXServer.shared
    @StateObject private var callManager = CallManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if store.currentUser == nil {
                    AuthGateView()
                } else {
                    MainTabView()
                }
            }
            .environmentObject(store)
            .environmentObject(server)
            .environmentObject(callManager)
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var store: PBXStore
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            TabView {
                DialerView()
                    .tabItem { Label("Keypad", systemImage: "circle.grid.3x3") }

                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

                RecentsView()
                    .tabItem { Label("Recents", systemImage: "clock") }

                VoicemailRecordingsView()
                    .tabItem { Label("Voicemail", systemImage: "recordingtape") }

                if store.currentUser?.isAdmin == true {
                    AdminPanelView()
                        .tabItem { Label("Admin", systemImage: "shield.lefthalf.filled") }
                }

                ServerAndAccountView()
                    .tabItem { Label("Server", systemImage: "server.rack") }
            }

            if let call = callManager.activeCall, call.state != .ringing {
                InCallHUDView(call: call)
                    .transition(.move(edge: .bottom))
            }

            if let toast = callManager.statusToast {
                VStack {
                    Text(toast)
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 4)
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: callManager.activeCall?.state)
    }
}
