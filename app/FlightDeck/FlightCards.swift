import SwiftUI

struct JourneyHero: View {
    let trip: Trip
    var leg: FlightLeg? { trip.nextLeg }
    var flight: FlightInfo? { leg?.snapshot?.flight }
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {
                Label("UP NEXT",systemImage:"airplane.departure").eyebrow().foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(trip.departure.formatted(.dateTime.month(.abbreviated).day())).eyebrow().foregroundStyle(.white.opacity(0.65))
            }
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text(trip.legs.last?.snapshot?.flight.destination.city.nonempty ?? trip.legs.last?.destinationIata ?? "Your next trip")
                        .font(.system(size:34,weight:.bold)).tracking(-1.3)
                    Text(trip.title.nonempty ?? (trip.legs.count > 1 ? "One journey. All your connections.":"Your next flight, at a glance."))
                        .font(.system(size:13)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength:4)
                Image(systemName:"arrow.up.right").font(.system(size:17,weight:.medium)).padding(11)
                    .background(.white.opacity(0.09),in:Circle())
            }
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:5) {
                    Text(leg?.origin ?? "—").font(.system(size:34,weight:.medium,design:.rounded)).tracking(1)
                    Text(FlightTime.clock(flight?.departure,zone:flight?.origin.timezone)).font(.system(size:17,weight:.medium,design:.monospaced))
                }
                RouteLine(color:.white.opacity(0.65)).padding(.horizontal,8)
                VStack(alignment:.trailing,spacing:5) {
                    Text(leg?.destination ?? "—").font(.system(size:34,weight:.medium,design:.rounded)).tracking(1)
                    Text(FlightTime.clock(flight?.arrival,zone:flight?.destination.timezone)).font(.system(size:17,weight:.medium,design:.monospaced))
                }
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height:1)
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(leg?.flightNumber ?? "").font(.system(size:13,weight:.bold,design:.monospaced))
                    Text(trip.legs.count>1 ? "\(trip.legs.count) flights · \(trip.route)":"Direct flight")
                        .font(.system(size:11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                StatusBadge(flight:flight,dark:true)
            }
        }.padding(24).foregroundStyle(.white)
            .background(LinearGradient(colors:[Deck.ink,Color(red:0.16,green:0.27,blue:0.34)],startPoint:.topLeading,endPoint:.bottomTrailing))
            .overlay(alignment:.topTrailing) {
                ZStack {
                    Circle().stroke(.white.opacity(0.04),lineWidth:34).frame(width:245,height:245).offset(x:100,y:-100)
                    Circle().stroke(.white.opacity(0.04),lineWidth:1).frame(width:160,height:160).offset(x:57,y:-57)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }.clipShape(RoundedRectangle(cornerRadius:28))
            .contentShape(RoundedRectangle(cornerRadius:28))
            .shadow(color:Deck.ink.opacity(0.12),radius:18,x:0,y:8)
            .accessibilityElement(children:.combine)
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
                Text("YOUR INCOMING AIRCRAFT").eyebrow().foregroundStyle(Deck.muted)
                if let inbound {
                    Text("\(inbound.origin.iata) → \(inbound.destination.iata)")
                        .font(.system(size:17,weight:.bold,design:.rounded)).foregroundStyle(Deck.ink)
                    Text("\(inbound.flightNumber) · \(inbound.statusLabel)")
                        .font(.system(size:12)).foregroundStyle(Deck.muted)
                } else {
                    Text("Waiting for its next assignment").font(.system(size:14,weight:.semibold)).foregroundStyle(Deck.ink)
                    Text(leg.snapshot?.inboundNote ?? "We’ll show the previous flight when it is confirmed.")
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
        }.deckCard(padding:18)
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
