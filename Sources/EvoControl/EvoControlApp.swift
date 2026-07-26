import AppKit
import SwiftUI

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct EvoControlApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup {
            MixerView()
                .environmentObject(store)
                .task {
                    DebugLog.reset()
                    store.prepareAudioAndRefreshDevices()
                }
                .background(WindowAccessor())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
