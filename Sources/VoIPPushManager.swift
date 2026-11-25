import Foundation
import Combine

final class VoIPPushManager: ObservableObject {
    static let shared = VoIPPushManager()
    @Published var voipPushTokenHex: String = "Disabled (Free Sideload)"
    private init() {}
    func start() {}
}
