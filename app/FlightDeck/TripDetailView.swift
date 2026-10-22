import SwiftUI

struct TripDetailView: View {
    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: String
    @State private var deleting = false
    var trip: Trip? { store.trips.first { $0.id == tripID } }
    var body: some View {
        FreshnessScrollView(lastUpdated:trip?.dataUpdatedAt,isRefreshing:store.isRefreshing,refresh:{ await store.refresh(force:true,tripID:tripID) }) {
            if let trip {
                VStack(alignment:.leading,spacing:24) {
                    Text(trip.isPast ? "IN YOUR FLIGHT JOURNAL":"YOUR JOURNEY").eyebrow().foregroundStyle(Deck.muted)
                    Text(trip.displayTitle).font(.system(size:32,weight:.bold)).tracking(-1.2)
                    Text(trip.route).font(.system(size:17,weight:.medium,design:.rounded)).foregroundStyle(Deck.muted)
                    ForEach(Array(trip.legs.enumerated()),id:\.element.id) { index, leg in
                        VStack(alignment:.leading,spacing:16) {
                            HStack {
                                Text("FLIGHT \(index+1) OF \(trip.legs.count)").eyebrow().foregroundStyle(Deck.muted)
                                Spacer()
                                Text(leg.departureDay.formatted(.dateTime.day().month(.abbreviated))).font(.system(size:12)).foregroundStyle(Deck.muted)
                            }
                            LegDetailCard(leg:leg)
                            if !leg.isPast {
                                VStack(alignment:.leading,spacing:10) {
                                    Text("INCOMING AIRCRAFT").eyebrow().foregroundStyle(Deck.muted)
                                    IncomingCard(leg:leg)
                                }
                            }
                            if let f = leg.snapshot?.flight {
                                HStack(spacing:14) {
                                    Image(systemName:"airplane").font(.system(size:28,weight:.light)).foregroundStyle(Deck.orange)
                                        .frame(width:52,height:52).background(Deck.orange.opacity(0.07),in:RoundedRectangle(cornerRadius:16))
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(leg.snapshot?.isSchedule == true ? "PLANNED AIRCRAFT TYPE":"YOUR AIRCRAFT").eyebrow().foregroundStyle(Deck.muted)
                                        Text(f.aircraftName).font(.system(size:16,weight:.semibold))
                                        Text(f.registration ?? "Registration not yet available").font(.system(size:12,design:.monospaced)).foregroundStyle(Deck.muted)
                                    }
                                    Spacer()
                                }.deckCard(padding:18)
                            }
                            if let issue = leg.issue ?? store.issues.first(where: { $0.legId == leg.id }) {
                                RefreshIssueView(issue:issue)
                            }
                            if let snapshot = leg.snapshot {
                                HStack(spacing:5) {
                                    Image(systemName:snapshot.isStale ? "clock.badge.exclamationmark":"checkmark.circle")
                                    Text("\(snapshot.isSchedule ? "Schedule checked":"Updated") \((FlightTime.date(snapshot.fetchedAt) ?? .distantPast).formatted(.relative(presentation:.named)))")
                                    if snapshot.isStale { Text("· May be outdated") }
                                }.font(.system(size:10)).foregroundStyle(Deck.muted)
                            } else {
                                Text("Saved to your itinerary. Live details become available close to departure.")
                                    .font(.footnote).foregroundStyle(Deck.muted)
                            }
                        }
                        if index < trip.legs.count-1 {
                            Label("Connection in \(leg.destination)",systemImage:"point.bottomleft.forward.to.point.topright.scurvepath")
                                .font(.system(size:12,weight:.semibold)).foregroundStyle(Deck.muted).padding(.leading,20)
                        }
                    }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(Deck.orange) }
                    Text("Times are local to each airport. Aircraft assignments can change.").font(.footnote).foregroundStyle(Deck.muted)
                }.padding(24)
            }
        }.background(Deck.paper).foregroundStyle(Deck.ink).navigationTitle("Trip details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Menu {
                        Button("Refresh",systemImage:"arrow.clockwise") { Task { await store.refresh(force:true,tripID:tripID) } }
                        Button("Delete trip",systemImage:"trash",role:.destructive) { deleting = true }
                    } label: { Image(systemName:"ellipsis.circle") }
                }
            }.confirmationDialog("Delete this trip from your flight journal?",isPresented:$deleting,titleVisibility:.visible) {
                Button("Delete trip",role:.destructive) { Task { await store.delete(tripID); if !store.trips.contains(where:{$0.id == tripID}) { dismiss() } } }
            }
    }
}

private struct LegDetailCard: View {
    let leg: FlightLeg
    var f: FlightInfo? { leg.snapshot?.flight }
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {
                Text(leg.flightNumber).font(.system(size:14,weight:.bold,design:.monospaced))
                Spacer()
                StatusBadge(flight:f)
            }
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:5) {
                    Text(leg.origin).font(.system(size:36,weight:.medium,design:.rounded))
                    Text(f?.origin.city ?? "Departure").font(.system(size:12)).foregroundStyle(Deck.muted)
                    Text(FlightTime.clock(f?.departure,zone:f?.origin.timezone)).font(.system(size:21,weight:.semibold,design:.monospaced)).padding(.top,7)
                    if (f?.departureDelayMinutes ?? 0)>0 {
                        Text(FlightTime.clock(f?.scheduledDeparture,zone:f?.origin.timezone)).font(.caption).strikethrough().foregroundStyle(Deck.muted)
                    }
                }
                RouteLine().padding(.horizontal,3)
                VStack(alignment:.trailing,spacing:5) {
                    Text(leg.destination).font(.system(size:36,weight:.medium,design:.rounded))
                    Text(f?.destination.city ?? "Arrival").font(.system(size:12)).foregroundStyle(Deck.muted)
                    Text(FlightTime.clock(f?.arrival,zone:f?.destination.timezone)).font(.system(size:21,weight:.semibold,design:.monospaced)).padding(.top,7)
                    if (f?.arrivalDelayMinutes ?? 0)>0 {
                        Text(FlightTime.clock(f?.scheduledArrival,zone:f?.destination.timezone)).font(.caption).strikethrough().foregroundStyle(Deck.muted)
                    }
                }
            }
            Divider().overlay(Deck.line)
            HStack {
                detail("DEPARTURE GATE",f?.departureGate ?? "—")
                Spacer()
                detail("TERMINAL",f?.departureTerminal ?? "—")
                Spacer()
                detail("ARRIVAL GATE",f?.arrivalGate ?? "—")
            }
        }.deckCard()
    }
    func detail(_ name:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text(name).font(.system(size:8,weight:.bold,design:.monospaced)).tracking(0.5).foregroundStyle(Deck.muted)
            Text(value).font(.system(size:18,weight:.semibold,design:.rounded))
        }
    }
}
