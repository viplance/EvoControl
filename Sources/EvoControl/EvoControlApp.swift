import SwiftUI

@main
struct EvoControlApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup {
            MixerView()
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 540)
                .task {
                    DebugLog.reset()
                    store.prepareAudioAndRefreshDevices()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
