import SwiftUI
import EventKit

@main
struct FlightDeckApp: App {
    @State private var store = FlightStore()
    @State private var calendar = CalendarImportStore()
    @Environment(\.scenePhase) private var phase
    @State private var launching = true
    var body: some Scene {
        WindowGroup {
            ZStack {
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
                }.allowsHitTesting(!launching).accessibilityHidden(launching)
            }.tint(Deck.ink).environment(store).environment(calendar).preferredColorScheme(.light)
                .statusBarHidden(launching)
                .overlayPreferenceValue(LaunchCardPreference.self) { anchor in
                    if launching {
                        GeometryReader { geometry in
                            LaunchCover(destination:anchor.map { geometry[$0] }) { launching = false }
                        }.ignoresSafeArea()
                    }
                }
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
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains(where:{ $0.hasPrefix("--uitesting") }),!args.contains("--uitesting-launch") { launching = false }
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
