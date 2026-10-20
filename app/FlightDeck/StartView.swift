import SwiftUI

struct StartView: View {
    @Environment(FlightStore.self) private var store
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:28) {
                    HStack(spacing:12) {
                        Image(systemName:"airplane.departure").font(.system(size:23,weight:.medium)).foregroundStyle(.white)
                            .frame(width:52,height:52).background(Deck.ink,in:RoundedRectangle(cornerRadius:17))
                        Text("FLIGHTDECK").eyebrow().foregroundStyle(Deck.ink)
                    }.padding(.top,24)
                    VStack(alignment:.leading,spacing:14) {
                        Text("Your journey,\nall in one place.").font(.system(size:36,weight:.bold)).tracking(-1.4)
                        Text("Your flights, connections and incoming aircraft. Connect your server to get started.")
                            .font(.subheadline).foregroundStyle(Deck.muted).lineSpacing(4)
                    }
                    if store.canResumeSession {
                        Button("Return to my account") { Task { await store.resumeSession() } }
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("resumeAccount")
                    }
                    ServerConnectionForm()
                    if let error = store.error {
                        Text(error).font(.footnote).foregroundStyle(Deck.orange)
                    }
                    VStack(spacing:10) {
                        Text("Just looking around?").font(.footnote).foregroundStyle(Deck.muted)
                        Button { store.useDemo() } label: {
                            Label("Explore the demo",systemImage:"sparkles").font(.subheadline.weight(.semibold))
                        }.accessibilityIdentifier("exploreDemo")
                    }.frame(maxWidth:.infinity).padding(.bottom,24)
                }.padding(.horizontal,24)
            }.background(Deck.paper).foregroundStyle(Deck.ink).toolbar(.hidden,for:.navigationBar)
        }
    }
}

struct ServerConnectionForm: View {
    @Environment(FlightStore.self) private var store
    @State private var address = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var server: ServerInfo?
    @State private var showingLogin = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("YOUR SERVER").eyebrow().foregroundStyle(Deck.muted)
            TextField("https://server.example.com:8080/flights",text:$address).textContentType(.URL).keyboardType(.URL)
                .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("serverAddress").submitLabel(.go).onSubmit { connect() }
            Button { connect() } label: {
                HStack {
                    if connecting { ProgressView().tint(.white) }
                    Text(connecting ? "Connecting…":"Connect to server").fontWeight(.semibold)
                    if !connecting { Image(systemName:"arrow.right") }
                }.frame(maxWidth:.infinity).padding(16).background(Deck.ink,in:RoundedRectangle(cornerRadius:14)).foregroundStyle(.white)
            }.disabled(connecting || address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("connectServer")
            if let error { Text(error).font(.footnote).foregroundStyle(Deck.orange) }
            Text("Connect to your own server or one you trust, then sign in or create an account. Ports and paths such as /flights are supported. HTTPS is added if omitted; a private certificate must be trusted on your phone.")
                .font(.system(size:11)).foregroundStyle(Deck.muted).fixedSize(horizontal:false,vertical:true)
        }.deckCard()
            .onAppear { address = store.address }
            .sheet(isPresented:$showingLogin,onDismiss:{ store.enterAccount() }) {
                if let server { AccountAccessView(address:address,server:server) }
            }
            .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer();Button("Done") { focused = false } } }
    }
    private func connect() {
        guard !connecting,!address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        focused = false;connecting = true;error = nil
        Task {
            do {
                let api = try APIClient(address:address)
                let info = try await api.send("/v1/server",as:ServerInfo.self)
                guard info.service == "FlightDeck",info.protocolVersion == 2 else {
                    throw ConnectionError.response("This server needs the account-enabled FlightDeck update.")
                }
                server = info;showingLogin = true
            } catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}
