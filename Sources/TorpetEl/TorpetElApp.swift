import SwiftUI

struct TorpetElApp: App {
    @StateObject private var store = PlugStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.anyAlarm ? "exclamationmark.triangle.fill" : "bolt.fill")
                if !store.menuTitle.isEmpty { Text(store.menuTitle).monospacedDigit() }
            }
            .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
