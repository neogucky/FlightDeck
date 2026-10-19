import SwiftUI

struct SettingsView: View {
    @Environment(FlightStore.self) private var store
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var connectionError: String?
    @State private var connected = false
    @FocusState private var focusedField: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text("MAKE IT YOURS").eyebrow().foregroundStyle(Deck.muted)
                    Text("Settings").font(.system(size:34,weight:.bold)).tracking(-1.2)
                    HStack(spacing:15) {
                        Image(systemName:store.isDemo ? "sparkles":"checkmark.shield").font(.system(size:25)).foregroundStyle(Deck.orange)
                        VStack(alignment:.leading,spacing:5) {
                            Text(store.isDemo ? "Exploring the demo":"Connected to your server").font(.system(size:16,weight:.semibold))
                            Text(store.isDemo ? "Sample flights. No live data or API charges.":store.address).font(.footnote).foregroundStyle(Deck.muted)
                        }
                        Spacer()
                    }.deckCard()
                    SectionTitle(title:"Your server")
                    VStack(alignment:.leading,spacing:18) {
                        VStack(alignment:.leading,spacing:8) {
                            Text("SERVER ADDRESS").eyebrow().foregroundStyle(Deck.muted)
                            TextField("https://flights.example.com",text:$address).textContentType(.URL).keyboardType(.URL)
                                .focused($focusedField,equals:"address")
                                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("serverAddress")
                        }
                        Divider()
                        VStack(alignment:.leading,spacing:8) {
                            Text("CONNECTION TOKEN").eyebrow().foregroundStyle(Deck.muted)
                            SecureField("From your server configuration",text:$token).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField,equals:"token")
                                .accessibilityIdentifier("connectionToken")
                        }
                        Button {
                            connecting = true; connectionError = nil; connected = false
                            Task {
                                do { try await store.connect(address:address,token:token); connected = true; token = "" }
                                catch { connectionError = error.localizedDescription }
                                connecting = false
                            }
                        } label: {
                            HStack {
                                if connecting { ProgressView().tint(.white) }
                                Text(connecting ? "Connecting…":"Connect & load flights").fontWeight(.semibold)
                            }.frame(maxWidth:.infinity).padding(15).background(Deck.ink,in:RoundedRectangle(cornerRadius:14)).foregroundStyle(.white)
                        }.disabled(connecting || address.isEmpty || token.isEmpty)
                        if let connectionError { Text(connectionError).font(.footnote).foregroundStyle(Deck.orange) }
                        if connected { Label("Connected. Your saved trips are ready.",systemImage:"checkmark.circle.fill").font(.footnote).foregroundStyle(Deck.green) }
                        Text("The token is kept in your iPhone’s Keychain. Your FlightAware API key stays on your server. A private server certificate must be trusted on your phone.")
                            .font(.system(size:11)).foregroundStyle(Deck.muted).fixedSize(horizontal:false,vertical:true)
                    }.deckCard()
                    if let usage = store.usage {
                        SectionTitle(title:"Data budget",detail:usage.month)
                        VStack(alignment:.leading,spacing:15) {
                            HStack(alignment:.firstTextBaseline) {
                                Text(usage.conservativeUsedUsd,format:.currency(code:"USD")).font(.system(size:29,weight:.semibold,design:.rounded))
                                Text("of \(usage.limitUsd.formatted(.currency(code:"USD"))) safety budget").font(.footnote).foregroundStyle(Deck.muted)
                            }
                            ProgressView(value:min(usage.conservativeUsedUsd,usage.limitUsd),total:usage.limitUsd).tint(usage.blocked ? Deck.orange:Deck.green)
                            Text(usage.blocked ? "Live lookups are paused. Your saved trips remain available.":"Conservative accounting reserves extra for each lookup and keeps $0.50 below the $5 ceiling.")
                                .font(.footnote).foregroundStyle(Deck.muted)
                            Text("\(usage.requestCount) reserved requests · Price review due \(usage.pricingValidUntil)")
                                .font(.system(size:10,design:.monospaced)).foregroundStyle(Deck.muted)
                        }.deckCard()
                    }
                    SectionTitle(title:"About FlightDeck")
                    VStack(alignment:.leading,spacing:14) {
                        Label("Updates when flight data is over 15 minutes old",systemImage:"arrow.clockwise")
                        Label("Saved trips available offline",systemImage:"icloud.and.arrow.down")
                        Label("Flight details powered by FlightAware",systemImage:"airplane")
                        Text("Contains AeroAPI data © FlightAware LLC \(Calendar.current.component(.year,from:Date()).formatted(.number.grouping(.never))).")
                            .font(.system(size:10)).foregroundStyle(Deck.muted)
                    }.font(.system(size:12)).deckCard()
                    if !store.demo {
                        Button("Explore demo flights") { store.useDemo() }.font(.subheadline).foregroundStyle(Deck.muted).frame(maxWidth:.infinity)
                    }
                    Text("FLIGHTDECK  /  0.1").eyebrow().foregroundStyle(Deck.muted.opacity(0.5)).frame(maxWidth:.infinity).padding(.bottom,16)
                }.padding(24)
            }.background(Deck.paper).foregroundStyle(Deck.ink).toolbar(.hidden,for:.navigationBar).scrollDismissesKeyboard(.interactively)
                .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer(); Button("Done") { focusedField = nil } } }
                .onAppear { address = store.address; token = TokenVault.read() }
        }
    }
}
