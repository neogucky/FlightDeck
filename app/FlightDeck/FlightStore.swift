import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class FlightStore {
    var trips: [Trip] = []
    var usage: Usage?
    var usageHistory: [UsagePeriod] = []
    var account: UserAccount?
    var issues: [RefreshIssue] = []
    var isRefreshing = false
    var error: String?
    var lastSynced: Date?
    var serverMode = "live"
    var demo = false
    var hasEnteredApp = false
    var address = ""
    private var session: SavedSession?
    private let defaults = UserDefaults.standard
    private var client: APIClient? {
        guard !demo,let session else { return nil }
        return try? APIClient(address:session.address,token:session.token)
    }
    var upcoming: [Trip] { trips.filter { !$0.isPast }.sorted { $0.departure < $1.departure } }
    var history: [Trip] { trips.filter(\.isPast).sorted { $0.departure > $1.departure } }
    var isDemo: Bool { demo || serverMode == "demo" }
    var isSignedIn: Bool { !demo && session != nil && account != nil }
    var canResumeSession: Bool { !isSignedIn && session != nil }
    var needsAPIKey: Bool { isSignedIn && serverMode == "live" && account?.hasApiKey == false }

    init() {
        address = defaults.string(forKey:"serverAddress") ?? ""
        session = TokenVault.readSession()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitesting") {
            demo = true;hasEnteredApp = true;session = nil
            let count = args.first(where: { $0.hasPrefix("--uitesting-flight-count=") })
                .flatMap { Int($0.replacingOccurrences(of:"--uitesting-flight-count=",with:"")) } ?? 2
            trips = DemoData.trips(nextTripLegCount:count)
        } else if args.contains("--uitesting-preserve") {
            demo = true;hasEnteredApp = true;session = nil
            trips = loadCache(demo:true)?.trips ?? []
        } else if args.contains("--uitesting-start") {
            session = nil
        } else if let saved = session, (FlightTime.date(saved.expiresAt) ?? .distantPast) > Date() {
            hasEnteredApp = true;address = saved.address;account = saved.account
            if let cached = loadCache(demo:false),cached.account?.id == saved.account.id { apply(cached) }
        } else {
            session = nil
        }
        purgeOldSnapshots()
    }

    private func active(_ token: String) -> Bool { !demo && session?.token == token }
    private func cacheURL(demo: Bool) -> URL? {
        let dir = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        if demo { return dir.appendingPathComponent("demo.json") }
        guard let session else { return nil }
        let identity = session.address+"/"+session.account.id
        let hash = SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
        return dir.appendingPathComponent("account-\(hash).json")
    }
    private func loadCache(demo: Bool) -> ServerState? {
        guard let url = cacheURL(demo:demo),let data = try? Data(contentsOf:url) else { return nil }
        return try? JSONCoding.decoder.decode(ServerState.self,from:data)
    }
    func persist() {
        guard let url = cacheURL(demo:demo) else { return }
        let state = ServerState(mode:demo ? "demo":serverMode,account:demo ? nil:account,trips:trips,usage:usage,issues:[])
        do {
            try JSONCoding.encoder.encode(state).write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "Changes could not be saved on this device. \(error.localizedDescription)" }
    }
    private func purgeOldSnapshots() {
        for i in trips.indices {
            for j in trips[i].legs.indices {
                if let snapshot = trips[i].legs[j].snapshot,
                   Date().timeIntervalSince(FlightTime.date(snapshot.fetchedAt) ?? .distantPast) > 29*86400 {
                    trips[i].legs[j].snapshot = nil
                }
            }
        }
    }
    private func apply(_ state: ServerState) {
        guard demo || state.account?.id == session?.account.id else { return }
        trips = state.trips;usage = state.usage;issues = state.issues;serverMode = state.mode
        if !demo { account = state.account }
        purgeOldSnapshots()
    }
    func signIn(address: String, username: String, password: String, register: Bool) async throws {
        let candidate = try APIClient(address:address)
        let auth = try await candidate.send(register ? "/v1/auth/register":"/v1/auth/login",method:"POST",
            body:JSONCoding.encoder.encode(LoginInput(username:username,password:password)),as:AuthSession.self)
        let canonical = candidate.baseURL.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        let authenticated = try APIClient(address:canonical,token:auth.sessionToken)
        let state = try await authenticated.request("/v1/state")
        guard state.account?.id == auth.account.id else { throw ConnectionError.response("The server returned a different account.") }
        let saved = SavedSession(address:canonical,token:auth.sessionToken,expiresAt:auth.expiresAt,account:auth.account)
        do { try TokenVault.saveSession(saved) }
        catch { try? await authenticated.perform("/v1/auth/logout");throw error }
        if let old = cacheURL(demo:false) { try? FileManager.default.removeItem(at:old) }
        session = saved;self.address = canonical;demo = false;account = auth.account
        usageHistory = [];isRefreshing = false;lastSynced = nil;error = nil
        defaults.set(canonical,forKey:"serverAddress")
        apply(state);persist()
    }
    func saveAPIKey(_ key: String) async throws {
        guard let client,let token = session?.token else { throw ConnectionError.unauthorized }
        do {
            let state = try await client.request("/v1/account/api-key",method:"PUT",body:JSONCoding.encoder.encode(KeyInput(apiKey:key)))
            guard active(token) else { return }
            apply(state);error = nil
            if var saved = session,let account { saved.account = account;try TokenVault.saveSession(saved);session = saved }
            persist()
        } catch { handle(error,token:token);throw error }
    }
    func removeAPIKey() async {
        guard let client,let token = session?.token else { return }
        do {
            let state = try await client.request("/v1/account/api-key",method:"DELETE")
            guard active(token) else { return };apply(state)
            if var saved = session,let account { saved.account = account;try TokenVault.saveSession(saved);session = saved }
            persist();error = nil
        } catch { handle(error,token:token) }
    }
    func logout(allDevices: Bool = false) async {
        let old = client
        var remoteFailed = false
        do { try await old?.perform(allDevices ? "/v1/auth/logout-all":"/v1/auth/logout") }
        catch { remoteFailed = true }
        do { try TokenVault.clear() }
        catch { self.error = error.localizedDescription;return }
        if let url = cacheURL(demo:false) { try? FileManager.default.removeItem(at:url) }
        session = nil;account = nil;usage = nil;usageHistory = [];issues = [];lastSynced = nil;isRefreshing = false
        demo = false;hasEnteredApp = false;serverMode = "live";trips = []
        error = remoteFailed ? "Signed out on this device. The server could not be reached to revoke the session; sign in and choose ‘Sign out all devices’ when connected.":nil
    }
    func useDemo() {
        demo = true;hasEnteredApp = true;account = nil;serverMode = "demo";isRefreshing = false;lastSynced = nil
        trips = loadCache(demo:true)?.trips ?? DemoData.trips();usage = nil;usageHistory = [];error = nil;issues = [];persist()
    }
    func leaveDemo() {
        demo = false;hasEnteredApp = false;account = nil;serverMode = "live";isRefreshing = false;lastSynced = nil
        trips = [];usage = nil;usageHistory = [];error = nil;issues = []
    }
    // Keep the connection page mounted until its sign-in/key-setup sheet is dismissed.
    func enterAccount() { if isSignedIn { hasEnteredApp = true } }
    func resumeSession() async {
        guard let saved = session else { return }
        demo = false;hasEnteredApp = true;address = saved.address;account = saved.account;usageHistory = []
        trips = [];usage = nil;issues = [];lastSynced = nil
        if let cached = loadCache(demo:false),cached.account?.id == saved.account.id { apply(cached) }
        await refresh()
    }
    private func handle(_ error: Error, token: String) {
        guard active(token) else { return }
        if case ConnectionError.unauthorized = error {
            if let url = cacheURL(demo:false) { try? FileManager.default.removeItem(at:url) }
            try? TokenVault.clear();session = nil;account = nil;trips = [];usage = nil;usageHistory = [];issues = [];isRefreshing = false;hasEnteredApp = false
        }
        self.error = error.localizedDescription
    }
    func refresh(force: Bool = false, tripID: String? = nil) async {
        guard !isRefreshing else { return }
        guard hasEnteredApp else { return }
        purgeOldSnapshots()
        if demo {
            isRefreshing = true
            try? await Task.sleep(for:.milliseconds(350))
            guard demo else { return }
            for i in trips.indices where tripID == nil || trips[i].id == tripID {
                for j in trips[i].legs.indices where !trips[i].legs[j].isPast { trips[i].legs[j].snapshot?.fetchedAt = FlightTime.iso(Date()) }
            }
            isRefreshing = false;lastSynced = Date();error = nil;persist();return
        }
        guard let client,let token = session?.token else { error = "Sign in to your server in Settings.";return }
        isRefreshing = true
        defer { if active(token) { isRefreshing = false } }
        do {
            let query = "/v1/refresh?force=\(force ? "true":"false")"+(tripID.map { "&trip_id=\($0)" } ?? "")
            let state = try await client.request(needsAPIKey ? "/v1/state":query,method:needsAPIKey ? "GET":"POST")
            guard active(token) else { return };apply(state);lastSynced = Date();error = nil;persist()
        } catch { handle(error,token:token) }
    }
    func refreshIfNeeded() async {
        guard !demo,session != nil else { return }
        if let lastSynced,Date().timeIntervalSince(lastSynced) < 60 { return }
        await refresh()
    }
    func fetchUsage(refreshProvider: Bool = false) async {
        guard let client,let token = session?.token else { return }
        do {
            let report = try await client.send(refreshProvider ? "/v1/usage/refresh":"/v1/usage",method:refreshProvider ? "POST":"GET",as:UsageReport.self)
            guard active(token) else { return };usage = report.usage;usageHistory = report.history;error = nil;persist()
        } catch { handle(error,token:token) }
    }
    func add(_ payload: NewTrip) async throws {
        if demo {
            let legs = payload.legs.map { l in
                FlightLeg(id:UUID().uuidString,flightNumber:l.flightNumber.canonicalFlightNumber,
                    departureDate:l.departureDate,originIata:nil,destinationIata:nil,snapshot:nil)
            }
            trips.append(Trip(id:UUID().uuidString,title:payload.title,createdAt:FlightTime.iso(Date()),legs:legs));persist();return
        }
        guard let client,let token = session?.token else { throw ConnectionError.unauthorized }
        do {
            let state = try await client.request("/v1/trips",method:"POST",body:JSONCoding.encoder.encode(payload))
            guard active(token) else { return };apply(state);lastSynced = Date();persist()
        } catch { handle(error,token:token);throw error }
    }
    func delete(_ id: String) async {
        if demo { trips.removeAll { $0.id == id };persist();return }
        guard let client,let token = session?.token else { return }
        do {
            let state = try await client.request("/v1/trips/\(id)",method:"DELETE")
            guard active(token) else { return };apply(state);persist()
        } catch { handle(error,token:token) }
    }
}
