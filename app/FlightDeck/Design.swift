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
    let flight: FlightInfo?
    var dark = false
    private var warning: Bool { flight?.cancelled == true || flight?.diverted == true || (flight?.departureDelayMinutes ?? 0) >= 5 }
    var body: some View {
        HStack(spacing:5) {
            Circle().fill(warning ? Deck.orange : (dark ? Color.mint:Deck.green)).frame(width:5,height:5)
            Text(flight?.statusLabel ?? "Awaiting status").font(.system(size:11,weight:.semibold))
        }.foregroundStyle(dark ? .white : warning ? Deck.orange:Deck.green)
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
