import SwiftUI

struct AccountAccessView: View {
    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let address: String
    let server: ServerInfo
    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var keyStep = false
    @FocusState private var focused: String?
    private var valid: Bool {
        username.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$",options:.regularExpression) != nil &&
        (12...128).contains(password.count)
    }
    var body: some View {
        NavigationStack {
            Group {
                if keyStep {
                    APIKeyForm { dismiss() }
                } else {
                    ScrollView {
                        VStack(alignment:.leading,spacing:24) {
                            Label("SERVER CONNECTED",systemImage:"checkmark.shield").eyebrow().foregroundStyle(Deck.green)
                            Text("Your flights.\nYour account.").font(.system(size:32,weight:.bold)).tracking(-1)
                            Text(address).font(.footnote).foregroundStyle(Deck.muted)
                            if server.registrationOpen {
                                Picker("Account",selection:$registering) {
                                    Text("Sign in").tag(false)
                                    Text("Register").tag(true)
                                }.pickerStyle(.segmented).accessibilityIdentifier("accountMode")
                            }
                            VStack(alignment:.leading,spacing:18) {
                                VStack(alignment:.leading,spacing:8) {
                                    Text("USERNAME").eyebrow().foregroundStyle(Deck.muted)
                                    TextField("Your username",text:$username).textContentType(.username)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .focused($focused,equals:"username").accessibilityIdentifier("accountUsername")
                                }
                                Divider()
                                VStack(alignment:.leading,spacing:8) {
                                    Text("PASSWORD").eyebrow().foregroundStyle(Deck.muted)
                                    SecureField(registering ? "At least 12 characters":"Your password",text:$password)
                                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .focused($focused,equals:"password").accessibilityIdentifier("accountPassword")
                                }
                            }.deckCard()
                            if registering {
                                Text("Choose a username with 3–32 letters, numbers, dots, underscores or hyphens, and a password with 12–128 characters. This account belongs to this server.")
                                    .font(.footnote).foregroundStyle(Deck.muted)
                            } else {
                                Text("Your session stays securely on this iPhone, so you can come back without signing in each time.")
                                    .font(.footnote).foregroundStyle(Deck.muted)
                            }
                            if let error { Text(error).font(.footnote).foregroundStyle(Deck.orange).accessibilityIdentifier("authError") }
                            Button {
                                focused = nil;busy = true;error = nil
                                Task {
                                    do {
                                        try await store.signIn(address:address,username:username,password:password,register:registering)
                                        password = ""
                                        if store.needsAPIKey { keyStep = true } else { dismiss() }
                                    } catch { self.error = error.localizedDescription }
                                    busy = false
                                }
                            } label: {
                                HStack {
                                    if busy { ProgressView().tint(.white) }
                                    Text(busy ? "Connecting…":registering ? "Create account":"Sign in").fontWeight(.semibold)
                                    if !busy { Image(systemName:"arrow.right") }
                                }.frame(maxWidth:.infinity).padding(18).foregroundStyle(.white)
                                    .background(valid ? Deck.ink:Deck.ink.opacity(0.35),in:RoundedRectangle(cornerRadius:16))
                            }.disabled(!valid || busy).accessibilityIdentifier("authenticate")
                        }.padding(24)
                    }.scrollDismissesKeyboard(.interactively)
                }
            }.background(Deck.paper).foregroundStyle(Deck.ink)
                .navigationTitle(keyStep ? "Flight data":registering ? "Create account":"Welcome back").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) { Button(keyStep ? "Set up later":"Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItemGroup(placement:.keyboard) {
                        if !keyStep { Spacer();Button("Done") { focused = nil } }
                    }
                }.interactiveDismissDisabled(busy)
                .onDisappear { password = "" }
        }
    }
}

struct APIKeySetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            APIKeyForm { dismiss() }
                .navigationTitle("Flight data").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct APIKeyForm: View {
    @Environment(FlightStore.self) private var store
    let completed: () -> Void
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Image(systemName:"key.horizontal").font(.system(size:30,weight:.light)).foregroundStyle(Deck.ink)
                    .frame(width:68,height:68).background(Deck.ink.opacity(0.06),in:RoundedRectangle(cornerRadius:20))
                Text(store.account?.hasApiKey == true ? "Update your flight data key.":"Bring your flights to life.")
                    .font(.system(size:30,weight:.bold)).tracking(-1)
                Text("Connect your own FlightAware AeroAPI account to see flight status and incoming aircraft.")
                    .font(.subheadline).foregroundStyle(Deck.muted).lineSpacing(3)
                VStack(alignment:.leading,spacing:16) {
                    step("1","Create a FlightAware account and enable AeroAPI with a plan suitable for your use.")
                    step("2","Open My AeroAPI and copy an API key from your account.")
                    step("3","Paste it below. We’ll verify account access before saving it.")
                    Link("Open FlightAware AeroAPI ↗",destination:URL(string:"https://www.flightaware.com/commercial/aeroapi/")!)
                        .font(.system(size:13,weight:.semibold)).foregroundStyle(Deck.ink)
                    Link("Open My AeroAPI ↗",destination:URL(string:"https://www.flightaware.com/aeroapi/portal/")!)
                        .font(.system(size:13,weight:.semibold)).foregroundStyle(Deck.ink)
                }.deckCard()
                VStack(alignment:.leading,spacing:10) {
                    Text("AEROAPI KEY").eyebrow().foregroundStyle(Deck.muted)
                    SecureField("Paste your API key",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused).accessibilityIdentifier("providerAPIKey")
                }.deckCard()
                Label("Your key is encrypted on \(URL(string:store.address)?.host ?? "your server") and is never sent back to the app. Use a server operator you trust.",systemImage:"lock.shield")
                    .font(.footnote).foregroundStyle(Deck.muted).fixedSize(horizontal:false,vertical:true)
                Text("API requests use your own FlightAware account. FlightDeck keeps a conservative monthly safety budget; replacing a key does not reset usage.")
                    .font(.footnote).foregroundStyle(Deck.muted)
                if let error { Text(error).font(.footnote).foregroundStyle(Deck.orange).accessibilityIdentifier("keyError") }
                Button {
                    focused = false;busy = true;error = nil
                    Task {
                        do { try await store.saveAPIKey(key);key = "";completed() }
                        catch { self.error = error.localizedDescription;key = "" }
                        busy = false
                    }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? "Verifying your key…":"Verify & save key").fontWeight(.semibold)
                    }.frame(maxWidth:.infinity).padding(18).foregroundStyle(.white)
                        .background(Deck.ink,in:RoundedRectangle(cornerRadius:16))
                }.disabled(busy || key.count<10).accessibilityIdentifier("saveAPIKey")
            }.padding(24)
        }.background(Deck.paper).foregroundStyle(Deck.ink).scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer();Button("Done") { focused = false } } }
            .interactiveDismissDisabled(busy).onDisappear { key = "" }
    }
    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment:.top,spacing:12) {
            Text(number).font(.system(size:11,weight:.bold,design:.monospaced)).frame(width:24,height:24)
                .background(Deck.paper,in:Circle()).foregroundStyle(Deck.ink)
            Text(text).font(.system(size:13)).foregroundStyle(Deck.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
}
