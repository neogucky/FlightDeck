import SwiftUI

struct SettingsView: View {
    @Environment(FlightStore.self) private var store
    @State private var busy = false
    @State private var showingKey = false
    @State private var removingKey = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text("MAKE IT YOURS").eyebrow().foregroundStyle(Deck.muted)
                    Text("Settings").font(.system(size:34,weight:.bold)).tracking(-1.2)
                    if store.isSignedIn,let account = store.account {
                        HStack(spacing:15) {
                            Image(systemName:"person.crop.circle.badge.checkmark").font(.system(size:30)).foregroundStyle(Deck.green)
                            VStack(alignment:.leading,spacing:5) {
                                Text(account.username).font(.system(size:20,weight:.bold)).accessibilityIdentifier("signedInUsername")
                                Text(store.address).font(.footnote).foregroundStyle(Deck.muted)
                                Text("Signed in on this device").font(.system(size:11)).foregroundStyle(Deck.green)
                            }
                            Spacer(minLength:0)
                        }.deckCard()
                        SectionTitle(title:"Flight data")
                        VStack(alignment:.leading,spacing:16) {
                            Label(account.hasApiKey ? "AeroAPI key connected":"Add your AeroAPI key",systemImage:account.hasApiKey ? "lock.shield.fill":"key.horizontal")
                                .font(.system(size:16,weight:.semibold)).accessibilityIdentifier("apiKeyStatus")
                            Text(account.hasApiKey ? "Stored encrypted on your server. The saved key cannot be viewed in the app.":"Connect your own FlightAware account to start tracking live flight information.")
                                .font(.footnote).foregroundStyle(Deck.muted)
                            if store.serverMode == "live" {
                                Button(account.hasApiKey ? "Replace API key":"Set up flight data") { showingKey = true }
                                    .font(.system(size:14,weight:.semibold)).foregroundStyle(Deck.ink).accessibilityIdentifier("configureAPIKey")
                            } else { Text("This server is running in demo mode.").font(.footnote).foregroundStyle(Deck.muted) }
                        }.deckCard()
                        VStack(spacing:16) {
                            Button("Sign out") { busy = true;Task { await store.logout();busy = false } }
                                .accessibilityIdentifier("signOut")
                            Button("Sign out all devices") { busy = true;Task { await store.logout(allDevices:true);busy = false } }
                            if account.hasApiKey {
                                Button("Remove saved API key",role:.destructive) { removingKey = true }
                            }
                        }.font(.subheadline).frame(maxWidth:.infinity).foregroundStyle(Deck.muted).disabled(busy)
                    } else {
                        HStack(spacing:15) {
                            Image(systemName:"sparkles").font(.system(size:25)).foregroundStyle(Deck.orange)
                            VStack(alignment:.leading,spacing:5) {
                                Text(store.demo ? "Exploring the demo":"Sign in to continue").font(.system(size:16,weight:.semibold))
                                Text("Connect your server to keep your own flight journal.").font(.footnote).foregroundStyle(Deck.muted)
                            }
                            Spacer()
                        }.deckCard()
                        if store.canResumeSession {
                            Button("Return to my account") { Task { await store.resumeSession() } }
                                .font(.subheadline).foregroundStyle(Deck.ink)
                        }
                        Button { store.leaveDemo() } label: {
                            Label("Connect to a server",systemImage:"arrow.right").font(.subheadline.weight(.semibold))
                                .frame(maxWidth:.infinity).padding(16).background(Deck.ink,in:RoundedRectangle(cornerRadius:14)).foregroundStyle(.white)
                        }.accessibilityIdentifier("leaveDemo")
                    }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(Deck.orange) }
                    SectionTitle(title:"About FlightDeck")
                    VStack(alignment:.leading,spacing:14) {
                        Label("Your session stays in this iPhone’s Keychain",systemImage:"lock.shield")
                        Label("Updates when flight data is over 15 minutes old",systemImage:"arrow.clockwise")
                        Label("Saved trips available offline",systemImage:"icloud.and.arrow.down")
                        Text("Contains AeroAPI data © FlightAware LLC \(Calendar.current.component(.year,from:Date()).formatted(.number.grouping(.never))).")
                            .font(.system(size:10)).foregroundStyle(Deck.muted)
                    }.font(.system(size:12)).deckCard()
                    if !store.demo {
                        Button("Explore demo flights") { store.useDemo() }.font(.subheadline).foregroundStyle(Deck.muted).frame(maxWidth:.infinity)
                    }
                    Text("FLIGHTDECK  /  0.2").eyebrow().foregroundStyle(Deck.muted.opacity(0.5)).frame(maxWidth:.infinity).padding(.bottom,16)
                }.padding(24)
            }.background(Deck.paper).foregroundStyle(Deck.ink).toolbar(.hidden,for:.navigationBar).scrollDismissesKeyboard(.interactively)
                .sheet(isPresented:$showingKey) { APIKeySetupView() }
                .confirmationDialog("Remove the saved API key? Live lookups will pause. Your flights and usage history will remain.",isPresented:$removingKey,titleVisibility:.visible) {
                    Button("Remove API key",role:.destructive) { Task { await store.removeAPIKey() } }
                }
        }
    }
}
