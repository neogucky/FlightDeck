import SwiftUI

struct JourneyHero: View {
    let trip: Trip
    private let mint = Color(red:156/255,green:228/255,blue:220/255)
    private var showsTimeline: Bool { trip.legs.count>1 }
    private var current: String? {
        trip.legs.first(where:{ !$0.isPast && $0.snapshot?.flight.actualDeparture != nil })?.id ?? trip.nextLeg?.id
    }
    private var destination: String {
        trip.legs.last?.snapshot?.flight.destination.city.nonempty ?? trip.legs.last?.destinationIata?.nonempty ?? "Your next trip"
    }
    private var countLabel: String {
        let count = trip.legs.count
        return count == 1 ? "Direct flight":"\(count) flights · \(max(0,count-1)) \(count == 2 ? "connection":"connections")"
    }
    private var spokenRoute: String {
        let segments = trip.legs.count<=3 ? trip.legs.map { "\($0.origin) to \($0.destination), flight \($0.flightNumber), \(shortAircraft($0))" }.joined(separator:"; "):
            "\(trip.legs.first?.origin ?? "—") to \(trip.legs.last?.destination ?? "—")"
        let active = trip.legs.first(where:{ $0.id == current })
        let focus = trip.legs.count<=3 ? (active.map { "; \($0.snapshot?.flight.actualDeparture != nil ? "In flight":"Next leg"): \($0.flightNumber)" } ?? ""):""
        return "Trip to \(destination). \(segments). \(countLabel). \(trip.status.label)\(focus)"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.center,spacing:16) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Trip to:").font(.system(size:13,weight:.medium)).foregroundStyle(.white.opacity(0.72))
                    Text(destination).font(.system(size:31,weight:.bold)).tracking(-1.1).lineLimit(2).minimumScaleFactor(0.8)
                }
                Spacer(minLength:0)
                VStack(alignment:.trailing,spacing:9) {
                    Text(trip.departure.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                        .font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.2).foregroundStyle(.white.opacity(0.68))
                    Image(systemName:"arrow.up.right").font(.system(size:14,weight:.medium))
                        .frame(width:29,height:29).background(.white.opacity(0.08),in:Circle())
                }
            }
            if (1...3).contains(trip.legs.count) {
                VStack(spacing:7) {
                    ForEach(Array(trip.legs.enumerated()),id:\.element.id) { index,leg in
                        segment(leg,first:index == 0,last:index == trip.legs.count-1)
                    }
                }
            } else {
                VStack(spacing:12) {
                    HStack(spacing:16) {
                        Text(trip.legs.first?.origin ?? "—").font(.system(size:34,weight:.medium,design:.rounded))
                        RouteLine(color:.white.opacity(0.65))
                        Text(trip.legs.last?.destination ?? "—").font(.system(size:34,weight:.medium,design:.rounded))
                    }
                    HStack {
                        Text(time(trip.legs.first,arrival:false));Spacer();Text(time(trip.legs.last,arrival:true))
                    }.font(.system(size:16,weight:.medium,design:.monospaced))
                }
            }
            VStack(spacing:15) {
                Rectangle().fill(.white.opacity(0.14)).frame(height:1)
                HStack {
                    Text(countLabel).font(.system(size:11)).foregroundStyle(.white.opacity(0.69))
                    Spacer(minLength:6);StatusBadge(trip:trip,dark:true).fixedSize()
                }
            }
        }.padding(22).foregroundStyle(.white).frame(maxWidth:.infinity,alignment:.leading)
            .background(Deck.navyGradient)
            .overlay(alignment:.topTrailing) {
                Circle().stroke(.white.opacity(0.035),lineWidth:30).frame(width:245,height:245).offset(x:104,y:-130)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }.clipShape(RoundedRectangle(cornerRadius:28))
            .contentShape(RoundedRectangle(cornerRadius:28)).shadow(color:Deck.ink.opacity(0.12),radius:18,x:0,y:8)
            .accessibilityElement(children:.ignore).accessibilityLabel(spokenRoute)
    }
    private func segment(_ leg: FlightLeg,first: Bool,last: Bool) -> some View {
        let active = leg.id == current,past = leg.isPast,airborne = !past && leg.snapshot?.flight.actualDeparture != nil
        return HStack(spacing:showsTimeline ? 10:0) {
            if showsTimeline {
                Color.clear.frame(width:16).overlay {
                    GeometryReader { geometry in
                        let h = geometry.size.height,start: CGFloat = first ? h/2:0,end: CGFloat = last ? h/2:h+7
                        Rectangle().fill(.white.opacity(0.17)).frame(width:1,height:max(0,end-start)).position(x:8,y:(start+end)/2)
                        Group {
                            if past {
                                Image(systemName:"checkmark").font(.system(size:10,weight:.medium)).foregroundStyle(.white.opacity(0.7))
                                    .frame(width:16,height:16).background(Deck.ink,in:Circle())
                            } else {
                                Circle().fill(active ? mint:Color(red:0.49,green:0.57,blue:0.61)).frame(width:active ? 8:6,height:active ? 8:6)
                                    .shadow(color:active ? mint.opacity(0.25):.clear,radius:4)
                            }
                        }.position(x:8,y:h/2)
                    }
                }
            }
            VStack(alignment:.leading,spacing:8) {
                Text(past ? "ARRIVED":active ? (airborne ? "IN FLIGHT":"NEXT LEG"):"LATER")
                    .font(.system(size:11,weight:.medium,design:.monospaced)).tracking(1.2).foregroundStyle(active ? mint:.white.opacity(0.6))
                HStack(alignment:.top,spacing:4) {
                    airport(leg.origin,time:time(leg,arrival:false),active:active,trailing:false)
                    VStack(spacing:3) {
                        Text(leg.flightNumber).font(.system(size:11,weight:.semibold,design:.monospaced))
                        Image(systemName:"arrow.right").font(.system(size:17,weight:.light)).frame(height:active ? 30:22)
                        Text(shortAircraft(leg)).font(.system(size:11)).lineLimit(1).minimumScaleFactor(0.8)
                    }.foregroundStyle(active ? mint:.white.opacity(0.65)).frame(width:78)
                    airport(leg.destination,time:time(leg,arrival:true),active:active,trailing:true)
                }
            }.padding(.vertical,active ? 14:10).padding(.leading,14).padding(.trailing,14)
        }.background {
            if active {
                if showsTimeline { TimelineHighlight().fill(mint.opacity(0.10)) }
                else { RoundedRectangle(cornerRadius:18).fill(mint.opacity(0.10)) }
            }
        }
    }
    private func airport(_ code: String,time: String,active: Bool,trailing: Bool) -> some View {
        VStack(alignment:trailing ? .trailing:.leading,spacing:6) {
            Text(code).font(.system(size:active ? 30:20,weight:.medium,design:.rounded)).tracking(-0.6)
                .lineLimit(1).minimumScaleFactor(0.65).frame(height:active ? 30:22)
            Text(time).font(.system(size:active ? 15:11,weight:.medium,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.8)
        }.foregroundStyle(.white.opacity(active ? 1:0.7)).padding(.top,17)
            .frame(maxWidth:.infinity,alignment:trailing ? .trailing:.leading)
    }
    private func shortAircraft(_ leg: FlightLeg) -> String {
        guard let flight = leg.snapshot?.flight,flight.aircraftType?.nonempty != nil else { return "—" }
        return flight.aircraftName.replacingOccurrences(of:"Airbus ",with:"").replacingOccurrences(of:"Boeing ",with:"")
    }
    private func time(_ leg: FlightLeg?,arrival: Bool) -> String {
        guard let leg else { return "—" }
        let f = leg.snapshot?.flight
        return FlightTime.clock(arrival ? f?.arrival ?? leg.calendarArrival:f?.departure ?? leg.calendarDeparture,
            zone:arrival ? f?.destination.timezone ?? leg.calendarTimeZone:f?.origin.timezone ?? leg.calendarTimeZone)
    }
}

private struct TimelineHighlight: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width,h = rect.height,c = h/2
        var p = Path();p.move(to:CGPoint(x:44,y:0));p.addLine(to:CGPoint(x:w-18,y:0))
        p.addQuadCurve(to:CGPoint(x:w,y:18),control:CGPoint(x:w,y:0));p.addLine(to:CGPoint(x:w,y:h-18))
        p.addQuadCurve(to:CGPoint(x:w-18,y:h),control:CGPoint(x:w,y:h));p.addLine(to:CGPoint(x:44,y:h))
        p.addQuadCurve(to:CGPoint(x:26,y:h-18),control:CGPoint(x:26,y:h));p.addLine(to:CGPoint(x:26,y:c+22))
        p.addCurve(to:CGPoint(x:8,y:c+5),control1:CGPoint(x:26,y:c+12),control2:CGPoint(x:20,y:c+5))
        p.addArc(center:CGPoint(x:8,y:c),radius:5,startAngle:.degrees(90),endAngle:.degrees(270),clockwise:false)
        p.addCurve(to:CGPoint(x:26,y:c-22),control1:CGPoint(x:20,y:c-5),control2:CGPoint(x:26,y:c-12))
        p.addLine(to:CGPoint(x:26,y:18));p.addQuadCurve(to:CGPoint(x:44,y:0),control:CGPoint(x:26,y:0));p.closeSubpath();return p
    }
}
