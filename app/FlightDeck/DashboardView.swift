import SwiftUI

struct DashboardView: View {
    @Environment(FlightStore.self) private var store
    @State private var adding = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    HStack(alignment:.center) {
                        VStack(alignment:.leading,spacing:8) {
                            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()).eyebrow().foregroundStyle(Deck.muted)
                            Text("Your flights").font(.system(size:35,weight:.bold)).tracking(-1.5).foregroundStyle(Deck.ink)
                        }
                        Spacer()
                        Button { adding = true } label: {
                            Image(systemName:"plus").font(.system(size:21,weight:.medium)).foregroundStyle(.white)
                                .frame(width:48,height:48).background(Deck.ink,in:Circle())
                        }.accessibilityLabel("Add flight").accessibilityIdentifier("addFlight")
                    }
                    if store.isDemo {
                        HStack(spacing:9) {
                            Image(systemName:"sparkles")
                            Text("Demo flights").fontWeight(.semibold)
                            Text("Connect your server in Settings.").foregroundStyle(Deck.muted)
                        }.font(.system(size:11)).foregroundStyle(Deck.ink).padding(.vertical,11).frame(maxWidth:.infinity)
                            .background(.white.opacity(0.8),in:Capsule())
                    }
                    if let error = store.error {
                        Label(error,systemImage:"wifi.exclamationmark").font(.footnote).foregroundStyle(Deck.orange).deckCard(padding:14)
                    }
                    if let next = store.upcoming.first {
                        NavigationLink(value:next.id) { JourneyHero(trip:next) }.buttonStyle(.plain).accessibilityIdentifier("nextTrip")
                        if let issue = next.legs.compactMap(\.issue).first ?? store.issues.first(where:{ issue in next.legs.contains(where:{ $0.id == issue.legId }) }) {
                            Label(issue.message,systemImage:"info.circle").font(.footnote).foregroundStyle(Deck.orange)
                                .accessibilityIdentifier("flightLookupIssue")
                        }
                        VStack(alignment:.leading,spacing:12) {
                            SectionTitle(title:"Incoming aircraft")
                            ForEach(next.legs.filter { !$0.isPast }) { leg in
                                NavigationLink(value:next.id) { IncomingCard(leg:leg) }.buttonStyle(.plain)
                                    .accessibilityIdentifier("incoming-\(leg.flightNumber)")
                            }
                        }
                        HStack(spacing:0) {
                            stat("\(store.upcoming.flatMap(\.legs).count)","UPCOMING FLIGHTS")
                            Rectangle().fill(Deck.line).frame(width:1,height:30)
                            stat("\(store.history.flatMap(\.legs).count)","FLIGHTS FLOWN")
                        }.padding(.vertical,5)
                        if store.upcoming.count > 1 {
                            SectionTitle(title:"On the horizon",detail:"\(store.upcoming.count-1) more \(store.upcoming.count == 2 ? "trip":"trips")")
                            ForEach(store.upcoming.dropFirst()) { trip in
                                NavigationLink(value:trip.id) { TripRow(trip:trip) }.buttonStyle(.plain)
                            }
                        }
                        HStack(spacing:5) {
                            if store.isRefreshing { ProgressView().controlSize(.mini) }
                            else { Image(systemName:"arrow.clockwise").font(.system(size:10)) }
                            Text(store.isRefreshing ? "Updating your flights…":next.legs.allSatisfy { $0.snapshot?.isSchedule == true } ? "Schedules checked daily · pull to refresh":"Live status refreshes when over 15 minutes old")
                                .font(.system(size:10))
                        }.foregroundStyle(Deck.muted).frame(maxWidth:.infinity).padding(.top,2)
                    } else {
                        EmptyFlights(history:false) { adding = true }
                    }
                    Text("ALL FLIGHT TIMES ARE LOCAL TO EACH AIRPORT").font(.system(size:8,weight:.medium,design:.monospaced))
                        .tracking(0.8).foregroundStyle(Deck.muted.opacity(0.7)).frame(maxWidth:.infinity).padding(.bottom,8)
                }.padding(.horizontal,24).padding(.top,16).padding(.bottom,20)
            }.background(Deck.paper).toolbar(.hidden,for:.navigationBar)
                .refreshable { await store.refresh(force:true) }
                .navigationDestination(for:String.self) { TripDetailView(tripID:$0) }
                .sheet(isPresented:$adding) { AddTripView() }
        }
    }
    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing:5) {
            Text(value).font(.system(size:25,weight:.semibold,design:.rounded)).foregroundStyle(Deck.ink)
            Text(title).font(.system(size:8,weight:.bold,design:.monospaced)).tracking(1.2).foregroundStyle(Deck.muted)
        }.frame(maxWidth:.infinity)
    }
}

struct HistoryView: View {
    @Environment(FlightStore.self) private var store
    @State private var adding = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    Text("YOUR FLIGHT JOURNAL").eyebrow().foregroundStyle(Deck.muted)
                    HStack {
                        Text("Past adventures").font(.system(size:32,weight:.bold)).tracking(-1.2)
                        Spacer()
                        Button { adding = true } label: { Image(systemName:"plus.circle.fill").font(.title).foregroundStyle(Deck.ink) }
                            .accessibilityLabel("Add past flight")
                    }
                    HStack(spacing:12) {
                        Image(systemName:"globe.europe.africa.fill").font(.system(size:34,weight:.light)).foregroundStyle(Deck.orange)
                        VStack(alignment:.leading,spacing:4) {
                            Text("\(store.history.flatMap(\.legs).count) flights, countless memories.").font(.system(size:16,weight:.semibold))
                            Text("Your trips stay with you, wherever you go.").font(.system(size:12)).foregroundStyle(Deck.muted)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).deckCard()
                    if store.history.isEmpty { EmptyFlights(history:true) { adding = true } }
                    ForEach(store.history) { trip in
                        NavigationLink(value:trip.id) { TripRow(trip:trip) }.buttonStyle(.plain)
                    }
                    if !store.history.isEmpty {
                        Text("Your saved itinerary is kept permanently. Live flight details expire after 29 days.")
                            .font(.footnote).foregroundStyle(Deck.muted).padding(.horizontal,4)
                    }
                }.padding(24)
            }.background(Deck.paper).foregroundStyle(Deck.ink).toolbar(.hidden,for:.navigationBar)
                .navigationDestination(for:String.self) { TripDetailView(tripID:$0) }
                .sheet(isPresented:$adding) { AddTripView() }
        }
    }
}
