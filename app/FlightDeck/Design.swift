import SwiftUI

enum Deck {
    static let ink = Color(red:0.10,green:0.16,blue:0.23)
    static let paper = Color(red:0.96,green:0.96,blue:0.94)
    static let muted = Color(red:0.45,green:0.49,blue:0.52)
    static let orange = Color(red:0.94,green:0.34,blue:0.16)
    static let green = Color(red:0.14,green:0.46,blue:0.35)
    static let line = Color(red:0.87,green:0.89,blue:0.88)
}

extension View {
    func deckCard(padding: CGFloat = 20) -> some View {
        self.padding(padding).background(.white,in:RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).stroke(Deck.line.opacity(0.6),lineWidth:0.7).allowsHitTesting(false))
    }
    func eyebrow() -> some View { self.font(.system(size:10,weight:.bold,design:.monospaced)).tracking(1.8) }
}

struct DeckField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title;self.content = content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).eyebrow().foregroundStyle(Deck.muted)
            content.textFieldStyle(.plain).frame(minHeight:28,alignment:.leading)
        }.contentShape(Rectangle())
    }
}

struct PlaneActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:reduceMotion)) { context in
            let phase = reduceMotion ? 0.5:context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:1.6)/1.6
            ZStack(alignment:.leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width:38,height:2).offset(y:5)
                Image(systemName:"airplane").font(.system(size:15,weight:.semibold))
                    .rotationEffect(.degrees(-12)).offset(x:phase*25,y:3-phase*7)
                    .opacity(reduceMotion ? 1:min(1,min(phase*7,(1-phase)*7)))
            }.foregroundStyle(.white).frame(width:44,height:22)
        }.accessibilityHidden(true)
    }
}

struct RouteLine: View {
    var color: Color = Deck.muted
    var body: some View {
        HStack(spacing:6) {
            Circle().stroke(color,lineWidth:1.5).frame(width:5,height:5)
            Rectangle().fill(color.opacity(0.35)).frame(height:1)
            Image(systemName:"airplane").font(.system(size:15,weight:.semibold))
            Rectangle().fill(color.opacity(0.35)).frame(height:1)
            Circle().stroke(color,lineWidth:1.5).frame(width:5,height:5)
        }.foregroundStyle(color).accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let label: String
    let warning: Bool
    let dark: Bool
    var pending: Bool { ["Awaiting status","Schedule only","Live status pending"].contains(label) }
    init(flight: FlightInfo?, dark: Bool = false) {
        label = flight?.statusLabel ?? "Awaiting status"
        warning = flight?.cancelled == true || flight?.diverted == true || (flight?.departureDelayMinutes ?? 0) >= 5
        self.dark = dark
    }
    init(trip: Trip, dark: Bool = false) {
        label = trip.status.label
        warning = trip.status.warning
        self.dark = dark
    }
    var body: some View {
        HStack(spacing:5) {
            if pending { Image(systemName:"clock").font(.system(size:10)) }
            else { Circle().fill(warning ? Deck.orange : (dark ? Color.mint:Deck.green)).frame(width:5,height:5) }
            Text(label).font(.system(size:11,weight:.semibold))
        }.foregroundStyle(dark ? .white : warning ? Deck.orange:pending ? Deck.muted:Deck.green)
            .padding(.horizontal,10).padding(.vertical,7)
            .background(dark ? Color.white.opacity(0.10) : (warning ? Deck.orange:Deck.green).opacity(0.08),in:Capsule())
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment:.firstTextBaseline) {
            Text(title).font(.system(size:20,weight:.bold)).tracking(-0.5)
            Spacer()
            if let detail { Text(detail).font(.system(size:12,weight:.medium)).foregroundStyle(Deck.muted) }
        }.foregroundStyle(Deck.ink)
    }
}

struct EmptyFlights: View {
    let history: Bool
    var add: (() -> Void)?
    var body: some View {
        VStack(spacing:16) {
            Image(systemName:history ? "book.closed":"airplane.departure").font(.system(size:36,weight:.light)).foregroundStyle(Deck.orange)
                .frame(width:90,height:90).background(Deck.orange.opacity(0.08),in:Circle())
            Text(history ? "Every journey, remembered." : "Where to next?").font(.title2.bold())
            Text(history ? "Completed flights appear here. You can also add past trips to start your flight journal." : "Add your next flight or connect a few legs. Everything you need will be waiting here.")
                .font(.subheadline).foregroundStyle(Deck.muted).multilineTextAlignment(.center).lineSpacing(4)
            if let add { Button(history ? "Add a past flight":"Add your first flight",action:add).buttonStyle(.borderedProminent).tint(Deck.ink) }
        }.frame(maxWidth:.infinity).padding(.vertical,44).padding(.horizontal,26)
    }
}
