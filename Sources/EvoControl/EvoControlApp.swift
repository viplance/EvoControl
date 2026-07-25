import SwiftUI

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
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
