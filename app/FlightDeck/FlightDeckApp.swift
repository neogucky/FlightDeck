import SwiftUI

@main
struct FlightDeckApp: App {
    @State private var store = FlightStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView().tabItem { Label("Trips",systemImage:"airplane.departure") }
                HistoryView().tabItem { Label("History",systemImage:"clock.arrow.circlepath") }
                SettingsView().tabItem { Label("Settings",systemImage:"slider.horizontal.3") }
            }.tint(Deck.ink).environment(store).preferredColorScheme(.light)
                .onChange(of:phase) { _,value in if value == .active { Task { await store.refreshIfNeeded() } } }
                .task {
                    await store.refreshIfNeeded()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for:.seconds(60)) } catch { break }
                        if phase == .active { await store.refreshIfNeeded() }
                    }
                }
        }
    }
}
