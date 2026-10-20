import Foundation
import CryptoKit

struct FlightCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
}

struct FlightCalendarEvent {
    let id: String
    let calendarID: String
    let calendarTitle: String
    let title: String
    let start: Date
    let end: Date
    let timeZone: TimeZone
    var allDay = false
    var cancelled = false
    var modified: Date = .distantPast
}

struct CalendarFlight: Identifiable, Equatable {
    let flightNumber: String
    let destination: String
    let departureDate: String
    let start: Date
    let end: Date
    let timeZoneID: String
    let calendarTitle: String
    var id: String { Self.key(number:flightNumber,day:departureDate) }
    static func key(number: String, day: String) -> String {
        digest(number.canonicalFlightNumber+"/"+day)
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier:timeZoneID) ?? .current
        return formatter.string(from:date)
    }
    var leg: NewLeg {
        NewLeg(flightNumber:flightNumber,departureDate:departureDate,
               calendarDeparture:iso(start),calendarArrival:iso(end),calendarTimeZone:timeZoneID)
    }
    var timeLabel: String {
        let formatter = DateFormatter();formatter.timeZone = TimeZone(identifier:timeZoneID)
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        let departure = formatter.string(from:start)
        formatter.dateFormat = "HH:mm"
        return departure+"–"+formatter.string(from:end)
    }
}

struct CalendarJourney: Identifiable {
    let flights: [CalendarFlight]
    var id: String { CalendarFlight.digest(flights.map(\.id).joined(separator:"/")) }
    var payload: NewTrip { NewTrip(title:"",legs:flights.map(\.leg),importId:id) }
}

enum CalendarFlightDetection {
    static func flights(in events: [FlightCalendarEvent], now: Date, until: Date) -> [CalendarFlight] {
        // Match the airline-generated title, rather than arbitrary numbers in appointments.
        let regex = try! NSRegularExpression(pattern:#"^\s*Flight\s+to\s+(.+?)\s*\(\s*([A-Z0-9]{2,3}\s*[0-9]{1,4}[A-Z]?)\s*\)\s*$"#,options:.caseInsensitive)
        var found: [String:(flight:CalendarFlight,modified:Date)] = [:]
        for event in events.sorted(by:{ $0.id < $1.id }) {
            guard !event.allDay,!event.cancelled,event.end>event.start,event.end>now,event.start<until,
                  let match = regex.firstMatch(in:event.title,range:NSRange(event.title.startIndex...,in:event.title)),
                  let destinationRange = Range(match.range(at:1),in:event.title),
                  let numberRange = Range(match.range(at:2),in:event.title) else { continue }
            let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.timeZone = event.timeZone;formatter.dateFormat = "yyyy-MM-dd"
            let flight = CalendarFlight(flightNumber:String(event.title[numberRange]).canonicalFlightNumber,
                destination:String(event.title[destinationRange]).trimmingCharacters(in:.whitespacesAndNewlines),
                departureDate:formatter.string(from:event.start),start:event.start,end:event.end,
                timeZoneID:event.timeZone.identifier,calendarTitle:event.calendarTitle)
            if let previous = found[flight.id],previous.modified>=event.modified { continue }
            found[flight.id] = (flight,event.modified)
        }
        return found.values.map(\.flight).sorted { $0.start == $1.start ? $0.id < $1.id:$0.start < $1.start }
    }

    static func journeys(from flights: [CalendarFlight]) -> [CalendarJourney] {
        var groups: [[CalendarFlight]] = []
        for flight in flights.sorted(by:{ $0.start == $1.start ? $0.id < $1.id:$0.start < $1.start }) {
            if let previous = groups.last?.last {
                let gap = flight.start.timeIntervalSince(previous.end)
                // A connection must depart after arrival and strictly less than 12h later.
                if gap>=0,gap<12*3600,groups[groups.count-1].count<8 {
                    groups[groups.count-1].append(flight);continue
                }
            }
            groups.append([flight])
        }
        return groups.map { CalendarJourney(flights:$0) }
    }

    static func existingKeys(_ trips: [Trip]) -> Set<String> {
        Set(trips.flatMap(\.legs).map { CalendarFlight.key(number:$0.flightNumber,day:$0.departureDate) })
    }
}
