import SwiftUI

@main
struct PhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cue: Pick & Place", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    // the debounced selection save must not lose the last mutation on Cmd-Q
    func applicationWillTerminate(_ notification: Notification) {
        model?.selection.saveNow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = model?.downloads.isActive == true || model?.isBulkWorking == true
        guard busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "An operation is in progress")
        alert.informativeText = String(
            localized: "Quitting now interrupts it. Photos not yet processed stay selected."
        )
        alert.addButton(withTitle: String(localized: "Keep Working"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
