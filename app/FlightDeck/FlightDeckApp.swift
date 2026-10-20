import SwiftUI
import EventKit

@main
struct FlightDeckApp: App {
    @State private var store = FlightStore()
    @State private var calendar = CalendarImportStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                if store.hasEnteredApp {
                    TabView {
                        DashboardView().tabItem { Label("Trips",systemImage:"airplane.departure") }
                        HistoryView().tabItem { Label("History",systemImage:"clock.arrow.circlepath") }
                        UsageView().tabItem { Label("Usage",systemImage:"chart.bar.xaxis") }
                        SettingsView().tabItem { Label("Settings",systemImage:"slider.horizontal.3") }
                    }
                } else {
                    StartView()
                }
            }.tint(Deck.ink).environment(store).environment(calendar).preferredColorScheme(.light)
                .onChange(of:phase) { _,value in if value == .active {
                    calendar.markChanged()
                    Task { await calendar.automaticScan(trips:store.trips);await store.refreshIfNeeded() }
                } }
                .onChange(of:store.calendarProfileID) { _,value in
                    calendar.configure(profile:value)
                    Task { await calendar.automaticScan(trips:store.trips) }
                }
                .onChange(of:store.trips) { _,value in calendar.reconcile(trips:value) }
                .onReceive(NotificationCenter.default.publisher(for:.EKEventStoreChanged).receive(on:DispatchQueue.main)) { _ in
                    calendar.markChanged()
                    Task { await calendar.automaticScan(trips:store.trips) }
                }
                .task {
                    calendar.configure(profile:store.calendarProfileID)
                    await calendar.automaticScan(trips:store.trips)
                    await store.refreshIfNeeded()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for:.seconds(60)) } catch { break }
                        if phase == .active { await calendar.automaticScan(trips:store.trips);await store.refreshIfNeeded() }
                    }
                }
        }
    }
}
