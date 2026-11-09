import UIKit

/// The iPad side of what the shared page model asks of the system. Prompts and
/// file pickers are shown by SwiftUI, which reads these requests.
@MainActor final class IOSPlatformServices: ObservableObject, PlatformServices {
    struct Confirmation: Identifiable { let id = UUID(); let title, detail, action, cancel: String; let answer: (Bool) -> Void }
    @Published var confirmation: Confirmation?
    /// Set while the app is waiting for the user to choose files.
    @Published var pickRequest: (imagesOnly: Bool, picked: ([URL]) -> Void)?
    var isActive: Bool { UIApplication.shared.applicationState == .active }
    var becameActive: Notification.Name { UIApplication.didBecomeActiveNotification }
    func applyAppearance(_ appearance: AppAppearance) {}
    func closeFrontWindow() {}
    func confirm(title: String, detail: String, action: String, cancel: String, _ answer: @escaping (Bool) -> Void) {
        confirmation = Confirmation(title:title,detail:detail,action:action,cancel:cancel,answer:answer)
    }
    func open(_ url: URL) { UIApplication.shared.open(url) }
    func reveal(_ url: URL) {}
    func pickFiles(message: String, imagesOnly: Bool, _ picked: @escaping ([URL]) -> Void) { pickRequest = (imagesOnly,picked) }
}
@MainActor func makePlatformServices() -> PlatformServices { IOSPlatformServices() }
