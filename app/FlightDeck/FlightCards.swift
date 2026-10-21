import SwiftUI

struct EmptyUpcomingCard: View {
    let add: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:32) {
            VStack(alignment:.leading,spacing:12) {
                Text("READY WHEN YOU ARE").eyebrow().foregroundStyle(.white.opacity(0.65))
                Text("No upcoming\nflights").font(.system(size:34,weight:.bold)).tracking(-1.2)
                    .fixedSize(horizontal:false,vertical:true)
                Text("Add your next trip when you’re ready.").font(.subheadline).foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal:false,vertical:true)
            }
            Button(action:add) {
                Text("Add a flight").font(.subheadline.weight(.semibold)).foregroundStyle(Deck.ink)
                    .frame(maxWidth:.infinity,minHeight:48).background(Deck.paper,in:RoundedRectangle(cornerRadius:14))
            }.buttonStyle(.plain).accessibilityIdentifier("emptyAddFlight")
        }.padding(24).foregroundStyle(.white).frame(maxWidth:.infinity,alignment:.leading)
            .background(Deck.navyGradient)
            .overlay(alignment:.topTrailing) {
                Circle().stroke(.white.opacity(0.04),lineWidth:34).frame(width:245,height:245).offset(x:100,y:-100)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }.clipShape(RoundedRectangle(cornerRadius:28))
            .shadow(color:Deck.ink.opacity(0.12),radius:18,x:0,y:8)
            .launchCard()
    }
}

struct IncomingCard: View {
    let leg: FlightLeg
    var inbound: FlightInfo? { leg.snapshot?.inbound }
    var body: some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:inbound == nil ? "airplane.circle":"airplane.arrival")
                .font(.system(size:20,weight:.medium)).foregroundStyle(Deck.green)
                .frame(width:44,height:44).background(Deck.green.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:6) {
                Text("FOR \(leg.flightNumber)").eyebrow().foregroundStyle(Deck.muted)
                if let inbound {
                    Text("\(inbound.origin.iata) → \(inbound.destination.iata)")
                        .font(.system(size:17,weight:.bold,design:.rounded)).foregroundStyle(Deck.ink)
                    Text("\(inbound.flightNumber) · \(inbound.statusLabel)")
                        .font(.system(size:12)).foregroundStyle(Deck.muted)
                } else {
                    Text(leg.snapshot == nil ? "Flight details not available yet":leg.snapshot?.isSchedule == true ? "Available closer to departure":"Waiting for its next assignment")
                        .font(.system(size:14,weight:.semibold)).foregroundStyle(Deck.ink)
                    Text(leg.snapshot?.inboundNote ?? "Aircraft information will appear after the flight details are found.")
                        .font(.system(size:12)).foregroundStyle(Deck.muted).fixedSize(horizontal:false,vertical:true)
                }
            }
            Spacer(minLength:0)
            if let inbound {
                VStack(alignment:.trailing,spacing:6) {
                    Text(FlightTime.clock(inbound.arrival,zone:inbound.destination.timezone))
                        .font(.system(size:17,weight:.semibold,design:.monospaced)).foregroundStyle(Deck.ink)
                    Text(inbound.actualArrival != nil ? "ARRIVED":"EXPECTED").font(.system(size:9,weight:.bold)).foregroundStyle(Deck.green)
                }
            }
        }.deckCard(padding:18).accessibilityElement(children:.combine)
    }
}

struct TripRow: View {
    let trip: Trip
    var body: some View {
        HStack(spacing:16) {
            VStack(spacing:3) {
                Text(trip.departure.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size:10,weight:.bold)).tracking(1)
                Text(trip.departure.formatted(.dateTime.day())).font(.system(size:26,weight:.semibold,design:.rounded))
            }.foregroundStyle(Deck.ink).frame(width:50,height:60).background(Deck.paper,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:7) {
                Text(trip.route).font(.system(size:17,weight:.bold,design:.rounded)).foregroundStyle(Deck.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text(trip.displayTitle).font(.system(size:12)).foregroundStyle(Deck.muted).lineLimit(1)
                Text(trip.legs.map(\.flightNumber).joined(separator:" · ")).font(.system(size:10,weight:.medium,design:.monospaced)).foregroundStyle(Deck.muted)
            }
            Spacer(minLength:0)
            Image(systemName:"chevron.right").font(.system(size:11,weight:.bold)).foregroundStyle(Deck.muted)
        }.deckCard(padding:16).accessibilityElement(children:.combine)
    }
}
