import Foundation
import Observation

@MainActor @Observable
final class FlightStore {
    var trips: [Trip] = []
    var usage: Usage?
    var issues: [RefreshIssue] = []
    var isRefreshing = false
    var error: String?
    var lastSynced: Date?
    var serverMode = "live"
    var demo: Bool
    var address: String
    private let defaults: UserDefaults
    private var client: APIClient? { try? APIClient(address:address, token:TokenVault.read()) }
    var upcoming: [Trip] { trips.filter { !$0.isPast }.sorted { $0.departure < $1.departure } }
    var history: [Trip] { trips.filter(\.isPast).sorted { $0.departure > $1.departure } }
    var isDemo: Bool { demo || serverMode == "demo" }

    init() {
        defaults = .standard
        demo = !defaults.bool(forKey:"connected")
        address = defaults.string(forKey:"serverAddress") ?? ""
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            demo = true
            let count = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--uitesting-flight-count=") })
                .flatMap { Int($0.replacingOccurrences(of:"--uitesting-flight-count=",with:"")) } ?? 2
            trips = DemoData.trips(nextTripLegCount:count)
        } else if ProcessInfo.processInfo.arguments.contains("--uitesting-preserve") {
            demo = true
            trips = loadCache(demo:true)?.trips ?? []
        } else if demo {
            trips = loadCache(demo:true)?.trips ?? DemoData.trips()
        } else if let cached = loadCache(demo:false) {
            apply(cached)
        }
        purgeOldSnapshots()
    }

    private func cacheURL(demo: Bool) -> URL {
        let dir = FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)[0]
        try? FileManager.default.createDirectory(at:dir, withIntermediateDirectories:true)
        return dir.appendingPathComponent(demo ? "demo.json" : "flights.json")
    }
    private func loadCache(demo: Bool) -> ServerState? {
        guard let data = try? Data(contentsOf:cacheURL(demo:demo)) else { return nil }
        return try? JSONCoding.decoder.decode(ServerState.self, from:data)
    }
    func persist() {
        let state = ServerState(mode:demo ? "demo" : serverMode, trips:trips, usage:usage, issues:[])
        do {
            let data = try JSONCoding.encoder.encode(state)
            try data.write(to:cacheURL(demo:demo), options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "Changes could not be saved on this device. \(error.localizedDescription)" }
    }
    private func purgeOldSnapshots() {
        for i in trips.indices {
            for j in trips[i].legs.indices {
                if let snapshot = trips[i].legs[j].snapshot,
                   Date().timeIntervalSince(FlightTime.date(snapshot.fetchedAt) ?? .distantPast) > 29 * 86400 {
                    trips[i].legs[j].snapshot = nil
                }
            }
        }
    }
    private func apply(_ state: ServerState) {
        trips = state.trips; usage = state.usage; issues = state.issues; serverMode = state.mode
        purgeOldSnapshots()
    }
    func connect(address: String, token: String) async throws {
        guard !isRefreshing else { throw ConnectionError.response("Please wait for the current refresh to finish.") }
        let candidate = try APIClient(address:address, token:token)
        let state = try await candidate.request("/v1/state")
        try TokenVault.save(token)
        self.address = address.trimmingCharacters(in:.whitespacesAndNewlines)
        defaults.set(self.address, forKey:"serverAddress"); defaults.set(true, forKey:"connected")
        demo = false; apply(state); lastSynced = Date(); error = nil; persist()
    }
    func useDemo() {
        demo = true; serverMode = "demo"; defaults.set(false, forKey:"connected")
        trips = loadCache(demo:true)?.trips ?? DemoData.trips(); usage = nil; error = nil; issues = []; persist()
    }
    func refresh(force: Bool = false, tripID: String? = nil) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        purgeOldSnapshots()
        if demo {
            try? await Task.sleep(for:.milliseconds(350))
            for i in trips.indices where tripID == nil || trips[i].id == tripID {
                for j in trips[i].legs.indices where !trips[i].legs[j].isPast {
                    trips[i].legs[j].snapshot?.fetchedAt = FlightTime.iso(Date())
                }
            }
            lastSynced = Date(); error = nil; persist(); return
        }
        guard let client else { error = "Connect your server in Settings."; return }
        do {
            let query = "/v1/refresh?force=\(force ? "true":"false")" + (tripID.map { "&trip_id=\($0)" } ?? "")
            apply(try await client.request(query, method:"POST"))
            lastSynced = Date(); error = nil; persist()
        } catch { self.error = error.localizedDescription }
    }
    func refreshIfNeeded() async {
        guard !demo else { return }
        // Refresh on foregrounding and every minute while visible; the server enforces the 15min TTL.
        if let lastSynced, Date().timeIntervalSince(lastSynced) < 60 { return }
        await refresh()
    }
    func add(_ payload: NewTrip) async throws {
        if demo {
            let legs = payload.legs.map { l -> FlightLeg in
                FlightLeg(id:UUID().uuidString, flightNumber:l.flightNumber.uppercased().replacingOccurrences(of:" ",with:""),
                    departureDate:l.departureDate,originIata:l.originIata?.uppercased().nonempty,
                    destinationIata:l.destinationIata?.uppercased().nonempty,snapshot:nil)
            }
            trips.append(Trip(id:UUID().uuidString,title:payload.title,createdAt:FlightTime.iso(Date()),legs:legs))
            persist(); return
        }
        guard let client else { throw ConnectionError.missingToken }
        apply(try await client.request("/v1/trips", method:"POST", body:JSONCoding.encoder.encode(payload)))
        lastSynced = Date(); persist()
    }
    func delete(_ id: String) async {
        if demo { trips.removeAll { $0.id == id }; persist(); return }
        guard let client else { error = "Connect your server in Settings."; return }
        do { apply(try await client.request("/v1/trips/\(id)",method:"DELETE")); persist() }
        catch { self.error = error.localizedDescription }
    }
}
