import SwiftUI
import UIKit

struct CalendarSettingsView: View {
    @Environment(FlightStore.self) private var store
    @Environment(CalendarImportStore.self) private var calendar
    @State private var showingResults = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("LESS TYPING, MORE TRAVELLING").eyebrow().foregroundStyle(Deck.orange)
                Text("Find your flights.").font(.system(size:31,weight:.bold)).tracking(-1)
                Text("Read upcoming flights from calendars already synced with your iPhone, including your Google calendars.")
                    .font(.subheadline).foregroundStyle(Deck.muted).lineSpacing(3)
                if !calendar.hasAccess {
                    VStack(alignment:.leading,spacing:16) {
                        Label("Calendar access",systemImage:"calendar.badge.plus").font(.headline)
                        Text("iOS requires full calendar permission to read events. FlightDeck only reads the calendars you choose and never changes your events.")
                            .font(.footnote).foregroundStyle(Deck.muted)
                        if calendar.permissionDenied {
                            Button("Open iOS Settings") { UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) }
                        } else {
                            Button("Allow calendar access") { Task { await calendar.requestAccess() } }
                                .accessibilityIdentifier("allowCalendarAccess")
                        }
                    }.deckCard()
                } else {
                    SectionTitle(title:"Choose calendars")
                    if calendar.calendars.isEmpty {
                        Text("No calendars are available. Add your Google account to iOS Calendar and enable calendar syncing, then return here.")
                            .font(.footnote).foregroundStyle(Deck.muted).deckCard()
                    }
                    VStack(spacing:16) {
                        ForEach(calendar.calendars) { source in
                            Toggle(isOn:Binding(get:{calendar.selectedCalendarIDs.contains(source.id)},set:{calendar.select(source.id,enabled:$0)})) {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(source.title).font(.subheadline.weight(.semibold))
                                    Text(source.source).font(.caption).foregroundStyle(Deck.muted)
                                }
                            }.tint(Deck.ink).accessibilityIdentifier("calendar-\(source.id)")
                                .disabled(calendar.isScanning || calendar.isImporting)
                        }
                    }.deckCard()
                }
                VStack(alignment:.leading,spacing:16) {
                    Toggle(isOn:Binding(get:{calendar.automatic},set:{ value in
                        calendar.setAutomatic(value)
                        if value { Task { await calendar.automaticScan(trips:store.trips) } }
                    })) {
                        Text("Automatically suggest flights").font(.subheadline.weight(.semibold))
                    }.tint(Deck.ink).accessibilityIdentifier("automaticCalendarSuggestions")
                        .disabled(!calendar.automatic && (!calendar.hasAccess || calendar.selectedCalendarIDs.isEmpty))
                    Text("Checks when FlightDeck opens and while you use it. New flights appear as suggestions on Trips. You decide what to add.")
                        .font(.footnote).foregroundStyle(Deck.muted)
                    Button {
                        Task { await calendar.scan(trips:store.trips);showingResults = true }
                    } label: {
                        HStack {
                            if calendar.isScanning { ProgressView().tint(.white) }
                            Label(calendar.isScanning ? "Searching…":"Search calendars now",systemImage:"magnifyingglass")
                        }.font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity).padding(16)
                            .background(Deck.ink,in:RoundedRectangle(cornerRadius:14)).foregroundStyle(.white)
                    }.disabled(!calendar.canSearch).accessibilityIdentifier("searchCalendarFlights")
                    if let lastScan = calendar.lastScan {
                        Text("Last searched \(lastScan.formatted(.relative(presentation:.named)))").font(.caption).foregroundStyle(Deck.muted)
                    }
                }.deckCard()
                if let error = calendar.error { Text(error).font(.footnote).foregroundStyle(Deck.orange) }
                VStack(alignment:.leading,spacing:14) {
                    Label("Looking for titles such as Flight to Frankfurt (LH 1189).",systemImage:"text.magnifyingglass")
                    Label("Flights departing less than 12 hours after the previous arrival are suggested as a connected trip.",systemImage:"point.bottomleft.forward.to.point.topright.scurvepath")
                    Label("Calendar scanning stays on this iPhone. Only flights you add are sent to your server.",systemImage:"iphone")
                }.font(.footnote).foregroundStyle(Deck.muted)
                if !calendar.dismissed.isEmpty {
                    VStack(alignment:.leading,spacing:12) {
                        Text("\(calendar.dismissed.count) dismissed \(calendar.dismissed.count == 1 ? "flight":"flights") won’t be suggested again, including during manual searches.")
                            .font(.footnote).foregroundStyle(Deck.muted)
                        Button("Reset dismissed suggestions") { calendar.resetDismissed() }
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("resetDismissedCalendarFlights")
                    }.deckCard()
                }
            }.padding(24)
        }.background(Deck.paper).foregroundStyle(Deck.ink).navigationTitle("Calendar import").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible,for:.navigationBar)
            .onAppear { calendar.reloadCalendars() }
            .sheet(isPresented:$showingResults) { CalendarSuggestionsView() }
    }
}

struct CalendarSuggestionsView: View {
    @Environment(FlightStore.self) private var store
    @Environment(CalendarImportStore.self) private var calendar
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text("FROM YOUR CALENDAR").eyebrow().foregroundStyle(Deck.orange)
                    Text(calendar.suggestions.isEmpty ? "You’re all caught up.":"Ready for your next trip?")
                        .font(.system(size:30,weight:.bold)).tracking(-1)
                    if calendar.suggestions.isEmpty {
                        Text("No new flights found in the next six months. Already tracked and dismissed flights are excluded.")
                            .font(.subheadline).foregroundStyle(Deck.muted).accessibilityIdentifier("noCalendarFlightSuggestions")
                    } else {
                        Text("Review your flights below. Dismiss a flight to stop future suggestions. Connections use your calendar’s times.")
                            .font(.subheadline).foregroundStyle(Deck.muted)
                    }
                    ForEach(calendar.journeys) { journey in
                        VStack(alignment:.leading,spacing:18) {
                            HStack {
                                Text(journey.flights.count>1 ? "\(journey.flights.count) CONNECTED FLIGHTS":"SINGLE FLIGHT").eyebrow().foregroundStyle(Deck.orange)
                                Spacer()
                                Button("Dismiss") { calendar.dismiss(journey.flights) }
                                    .font(.caption).foregroundStyle(Deck.muted).accessibilityIdentifier("dismissJourney-\(journey.flights[0].flightNumber)")
                            }
                            ForEach(journey.flights) { flight in
                                HStack(alignment:.top,spacing:12) {
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(flight.flightNumber).font(.system(size:19,weight:.semibold,design:.monospaced))
                                        Text("To \(flight.destination)").font(.subheadline.weight(.medium))
                                        Text(flight.timeLabel).font(.caption).foregroundStyle(Deck.muted)
                                        Text("\(flight.timeZoneID) · \(flight.calendarTitle)").font(.system(size:10)).foregroundStyle(Deck.muted)
                                    }
                                    Spacer(minLength:0)
                                    Button { calendar.dismiss([flight]) } label: { Image(systemName:"xmark.circle").foregroundStyle(Deck.muted) }
                                        .accessibilityLabel("Don’t suggest \(flight.flightNumber) again")
                                        .accessibilityIdentifier("dismissCalendar-\(flight.flightNumber)")
                                }
                            }
                            Button {
                                Task { if await calendar.add([journey],to:store),calendar.suggestions.isEmpty { dismiss() } }
                            } label: {
                                Label(journey.flights.count>1 ? "Add connected trip":"Add flight",systemImage:"plus")
                                    .font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity).padding(14)
                                    .background(Deck.ink,in:RoundedRectangle(cornerRadius:14)).foregroundStyle(.white)
                            }.accessibilityIdentifier("addCalendarJourney-\(journey.flights[0].flightNumber)")
                        }.deckCard().disabled(calendar.isImporting)
                    }
                    if let error = calendar.error { Text(error).font(.footnote).foregroundStyle(Deck.orange) }
                    if !calendar.suggestions.isEmpty {
                        Text("Calendar times are shown in each event’s timezone. Adding flights may use your AeroAPI budget to load schedules, status and aircraft information.")
                            .font(.footnote).foregroundStyle(Deck.muted)
                    }
                }.padding(24)
            }.background(Deck.paper).foregroundStyle(Deck.ink)
                .navigationTitle("Calendar flights").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarLeading) { Button(calendar.suggestions.isEmpty ? "Done":"Later") { dismiss() }.disabled(calendar.isImporting) } }
                .safeAreaInset(edge:.bottom) {
                    if calendar.suggestions.count>1 {
                        Button {
                            let journeys = calendar.journeys
                            Task { if await calendar.add(journeys,to:store) { dismiss() } }
                        } label: {
                            HStack {
                                if calendar.isImporting { ProgressView().tint(.white) }
                                Text(calendar.isImporting ? "Adding flights…":"Add all \(calendar.suggestions.count) flights").fontWeight(.semibold)
                            }.frame(maxWidth:.infinity).padding(18).foregroundStyle(.white).background(Deck.ink,in:RoundedRectangle(cornerRadius:16))
                        }.disabled(calendar.isImporting).padding(20).background(Deck.paper).accessibilityIdentifier("addAllCalendarFlights")
                    }
                }.interactiveDismissDisabled(calendar.isImporting)
        }
    }
}
