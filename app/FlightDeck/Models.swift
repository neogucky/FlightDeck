import Foundation

enum FlightTime {
    static func relative(_ date: Date,now: Date = Date()) -> String {
        let formatter=RelativeDateTimeFormatter();formatter.locale=Locale(identifier:"en")
        formatter.unitsStyle = .full
        return formatter.localizedString(for:min(date,now),relativeTo:now)
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
    static func dayDate(_ value: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: value) ?? .distantFuture
    }
    static func clock(_ value: String?, zone: String? = nil) -> String {
        guard let date = date(value) else { return "—" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let zone { f.timeZone = TimeZone(identifier: zone) }
        return f.string(from: date)
    }
}

struct Airport: Codable, Hashable {
    var iata: String
    var name: String
    var city: String
    var timezone: String
}

struct FlightInfo: Codable, Hashable {
    var providerId: String?
    var flightNumber: String
    var origin: Airport
    var destination: Airport
    var status: String
    var cancelled: Bool
    var diverted: Bool
    var registration: String?
    var aircraftType: String?
    var `operator`: String?
    var scheduledDeparture: String?
    var estimatedDeparture: String?
    var actualDeparture: String?
    var scheduledArrival: String?
    var estimatedArrival: String?
    var actualArrival: String?
    var departureGate: String?
    var arrivalGate: String?
    var departureTerminal: String?
    var arrivalTerminal: String?
    var arrivalDelayMinutes: Int
    var departureDelayMinutes: Int
    var progress: Int?
    var inboundProviderId: String?
    var departure: String? { actualDeparture ?? estimatedDeparture ?? scheduledDeparture }
    var arrival: String? { actualArrival ?? estimatedArrival ?? scheduledArrival }
    var statusLabel: String {
        if cancelled { return "Cancelled / not tracked" }
        if diverted { return "Diverted" }
        if actualArrival != nil { return "Arrived" }
        if actualDeparture != nil { return "In flight" }
        if departureDelayMinutes >= 5 { return "+\(departureDelayMinutes) min" }
        return status.lowercased().contains("scheduled") ? "On time" : status
    }
    var aircraftName: String {
        let names = ["A20N":"Airbus A320neo", "A21N":"Airbus A321neo", "A320":"Airbus A320", "A319":"Airbus A319", "A321":"Airbus A321", "A359":"Airbus A350-900", "B738":"Boeing 737-800", "B38M":"Boeing 737 MAX 8", "B77W":"Boeing 777-300ER", "B789":"Boeing 787-9", "BCS3":"Airbus A220-300", "E190":"Embraer 190"]
        return names[aircraftType ?? ""] ?? aircraftType ?? "Aircraft not assigned"
    }
}

struct FlightSnapshot: Codable, Hashable {
    var fetchedAt: String
    var flight: FlightInfo
    var inbound: FlightInfo?
    var inboundNote: String?
    var source: String? = nil
    var isSchedule: Bool { source == "schedule" || flight.status == "Schedule only" }
    var isStale: Bool { Date().timeIntervalSince(FlightTime.date(fetchedAt) ?? .distantPast) >= (isSchedule ? 86400:900) }
}

struct FlightLeg: Codable, Identifiable, Hashable {
    var id: String
    var flightNumber: String
    var departureDate: String
    var originIata: String?
    var destinationIata: String?
    var snapshot: FlightSnapshot?
    var issue: RefreshIssue? = nil
    var calendarDeparture: String? = nil
    var calendarArrival: String? = nil
    var calendarTimeZone: String? = nil
    var automaticRefreshIntervalSeconds: Int? = nil
    var automaticTrackingStartsAt: String? = nil
    var isDataStale: Bool {
        guard let snapshot else { return true }
        guard let interval=automaticRefreshIntervalSeconds else { return snapshot.isStale }
        return interval>0 && Date().timeIntervalSince(FlightTime.date(snapshot.fetchedAt) ?? .distantPast)>=Double(interval)
    }
    var automaticRefreshDescription: String {
        switch automaticRefreshIntervalSeconds {
        case 900: "Refreshes every 15 minutes while app is open"
        case 7200: "Refreshes every 2 hours while app is open"
        case 0: automaticTrackingStartsAt == nil ? "Pull to update flight details":"Automatic tracking starts 48h before departure · pull to refresh"
        default: "Automatic refresh timing is managed by your server"
        }
    }
    var origin: String { snapshot?.flight.origin.iata ?? originIata ?? "—" }
    var destination: String { snapshot?.flight.destination.iata ?? destinationIata ?? "—" }
    func readyAircraftAirport(at now: Date = Date()) -> Airport? {
        guard let snapshot,!snapshot.isSchedule,let incoming=snapshot.inbound,
              !snapshot.flight.cancelled,!snapshot.flight.diverted,
              snapshot.flight.actualDeparture == nil,snapshot.flight.actualArrival == nil,
              !incoming.cancelled,!incoming.diverted,
              let arrival=FlightTime.date(incoming.actualArrival),
              now.timeIntervalSince(arrival)>2*3600,
              incoming.destination.iata==snapshot.flight.origin.iata,
              snapshot.flight.origin.iata.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil else { return nil }
        let assigned=snapshot.flight.registration?.trimmingCharacters(in:.whitespacesAndNewlines).uppercased().nonempty
        let previous=incoming.registration?.trimmingCharacters(in:.whitespacesAndNewlines).uppercased().nonempty
        if let assigned,let previous,assigned != previous { return nil }
        let link=snapshot.flight.inboundProviderId?.nonempty
        if let link,link != incoming.providerId { return nil }
        guard (assigned != nil && assigned==previous) || (link != nil && link==incoming.providerId) else { return nil }
        return snapshot.flight.origin
    }
    var departureDay: Date { FlightTime.dayDate(departureDate) }
    var isPast: Bool {
        if snapshot?.flight.actualArrival != nil { return true }
        return departureDay < Calendar.current.startOfDay(for: Date()) &&
            (FlightTime.date(snapshot?.flight.arrival) ?? departureDay).addingTimeInterval(6 * 3600) < Date()
    }
}

struct Trip: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var createdAt: String
    var legs: [FlightLeg]
    var isPast: Bool { !legs.isEmpty && legs.allSatisfy(\.isPast) }
    var departure: Date { legs.first?.departureDay ?? .distantFuture }
    var route: String { ([legs.first?.origin ?? "—"] + legs.map(\.destination)).joined(separator: " → ") }
    var displayTitle: String {
        if !title.isEmpty { return title }
        return legs.last?.snapshot?.flight.destination.city.nonempty ?? legs.last?.destinationIata ?? "Upcoming trip"
    }
    var nextLeg: FlightLeg? { legs.first(where: { !$0.isPast }) ?? legs.first }
    var dataUpdatedAt: Date? {
        let relevant=isPast ? legs:legs.filter { !$0.isPast }
        let dates=relevant.compactMap { FlightTime.date($0.snapshot?.fetchedAt) }
        return !relevant.isEmpty && dates.count==relevant.count ? dates.min():nil
    }
    var status: JourneyStatus {
        if isPast { return JourneyStatus(label:"Arrived") }
        let remaining = legs.filter { !$0.isPast }
        let flights = remaining.compactMap { $0.snapshot?.flight }
        if flights.contains(where: { $0.cancelled }) { return JourneyStatus(label:"Flight cancelled",warning:true) }
        if flights.contains(where: { $0.diverted }) { return JourneyStatus(label:"Flight diverted",warning:true) }
        if flights.contains(where: { max($0.departureDelayMinutes,$0.arrivalDelayMinutes) >= 5 }) {
            return JourneyStatus(label:"Flight delayed",warning:true)
        }
        if flights.contains(where: { $0.actualDeparture != nil }) { return JourneyStatus(label:"In progress") }
        guard !remaining.isEmpty, flights.count == remaining.count else { return JourneyStatus(label:"Awaiting status") }
        if flights.contains(where: { $0.status == "Schedule only" }) {
            return JourneyStatus(label:flights.allSatisfy { $0.status == "Schedule only" } ? "Schedule only":"Live status pending")
        }
        if remaining.count < legs.count { return JourneyStatus(label:"Connecting") }
        if flights.allSatisfy({ $0.statusLabel == "On time" }) {
            return JourneyStatus(label:legs.count > 1 ? "All on time":"On time")
        }
        return JourneyStatus(label:flights.count == 1 ? flights[0].statusLabel:"Check status")
    }
}

struct JourneyStatus: Equatable {
    var label: String
    var warning = false
}

extension String {
    var nonempty: String? { isEmpty ? nil : self }
    var canonicalFlightNumber: String { components(separatedBy:.whitespacesAndNewlines).joined().uppercased() }
}

struct Usage: Codable {
    var month: String
    var limitUsd: Double
    var hardLimitUsd: Double
    var reservedUsd: Double
    var providerReportedUsd: Double
    var conservativeUsedUsd: Double
    var remainingUsd: Double
    var requestCount: Int
    var pricingValidUntil: String
    var blocked: Bool
    var accountCheckedAt: String?
    var pendingEstimatedUsd: Double? = nil
    var pendingRequestCount: Int? = nil
    var reportedThrough: String? = nil
    var reportingDelaySeconds: Int? = nil
    var predictedPendingCosts: Double { pendingEstimatedUsd ?? reservedUsd }
}

struct RefreshIssue: Codable, Identifiable, Hashable {
    var legId: String
    var code: String
    var message: String
    var attemptedAt: String? = nil
    var httpStatus: Int? = nil
    var id: String { legId + code }
}

struct ServerState: Codable {
    var mode: String
    var account: UserAccount? = nil
    var trips: [Trip]
    var usage: Usage?
    var issues: [RefreshIssue]
}

struct UserAccount: Codable, Equatable {
    var id: String
    var username: String
    var hasApiKey: Bool
    var apiKeyUpdatedAt: String?
}

struct ServerInfo: Decodable {
    var service: String
    var protocolVersion: Int
    var registrationOpen: Bool
    var mode: String
}

struct AuthSession: Decodable {
    var sessionToken: String
    var expiresAt: String
    var account: UserAccount
}

struct SavedSession: Codable {
    var address: String
    var token: String
    var expiresAt: String
    var account: UserAccount
}

struct UsagePeriod: Decodable, Identifiable {
    var month: String
    var reservedUsd: Double
    var providerReportedUsd: Double
    var conservativeUsedUsd: Double
    var requestCount: Int
    var id: String { month }
}

struct UsageReport: Decodable {
    var usage: Usage
    var history: [UsagePeriod]
}

struct LoginInput: Encodable { var username: String; var password: String }
struct KeyInput: Encodable { var apiKey: String }

struct NewLeg: Encodable, Identifiable {
    var id = UUID()
    var flightNumber = ""
    var departureDate = FlightTime.day(Date())
    var calendarDeparture: String? = nil
    var calendarArrival: String? = nil
    var calendarTimeZone: String? = nil
    enum CodingKeys: String, CodingKey { case flightNumber, departureDate, calendarDeparture, calendarArrival, calendarTimeZone }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy:CodingKeys.self)
        try container.encode(flightNumber.canonicalFlightNumber,forKey:.flightNumber)
        try container.encode(departureDate,forKey:.departureDate)
        try container.encodeIfPresent(calendarDeparture,forKey:.calendarDeparture)
        try container.encodeIfPresent(calendarArrival,forKey:.calendarArrival)
        try container.encodeIfPresent(calendarTimeZone,forKey:.calendarTimeZone)
    }
}

struct NewTrip: Encodable {
    var title: String
    var legs: [NewLeg]
    var importId: String? = nil
}

enum JSONCoding {
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }
}
