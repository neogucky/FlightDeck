import Foundation

@main enum CalendarDetectionTests {
    static func check(_ value: @autoclosure () -> Bool,_ message:String) { precondition(value(),message) }
    static func date(_ value:String) -> Date { FlightTime.date(value)! }
    static func event(_ id:String,_ title:String,_ start:String,_ end:String,zone:String = "Europe/Berlin") -> FlightCalendarEvent {
        FlightCalendarEvent(id:id,calendarID:"travel",calendarTitle:"Travel",title:title,start:date(start),end:date(end),timeZone:TimeZone(identifier:zone)!)
    }
    static func main() throws {
        let now = date("2026-10-20T00:00:00Z"),until = date("2027-04-20T00:00:00Z")
        let first = event("a","Flight to Frankfurt (LH 1189)","2026-10-23T08:00:00Z","2026-10-23T10:00:00Z")
        let second = event("b","Flight to Zurich (lx  1107)","2026-10-23T11:00:00Z","2026-10-23T12:00:00Z")
        let third = event("c","Flight to Hamburg (LX1052)","2026-10-24T00:00:00Z","2026-10-24T02:00:00Z")
        var cancelled = first;cancelled.cancelled = true
        var allDay = first;allDay.allDay = true
        let events = [first,second,third,first,cancelled,allDay,
            event("meeting","Team meeting (LH 1189)","2026-10-23T08:00:00Z","2026-10-23T10:00:00Z"),
            event("old","Flight to Paris (AF123)","2026-10-19T08:00:00Z","2026-10-19T10:00:00Z")]
        let flights = CalendarFlightDetection.flights(in:events,now:now,until:until)
        check(flights.count == 3,"Only valid upcoming flights, deduplicated, should match")
        check(flights[0].flightNumber == "LH1189" && flights[1].flightNumber == "LX1107","Normalize flight numbers")
        let groups = CalendarFlightDetection.journeys(from:flights)
        check(groups.map(\.flights.count) == [2,1],"A 12-hour gap must split; a one-hour gap must connect")
        let overlap = event("overlap","Flight to London (BA123)","2026-10-23T09:00:00Z","2026-10-23T10:30:00Z")
        let overlapping = CalendarFlightDetection.flights(in:[first,overlap],now:now,until:until)
        check(CalendarFlightDetection.journeys(from:overlapping).count == 2,"Overlapping flights cannot be a connection")
        let midnight = event("night","Flight to Tokyo (LX 160)","2026-10-23T22:30:00Z","2026-10-24T10:00:00Z")
        let night = CalendarFlightDetection.flights(in:[midnight],now:now,until:until)[0]
        check(night.departureDate == "2026-10-24","Use event timezone, not UTC or device date")
        check(night.leg.calendarDeparture!.hasSuffix("+02:00"),"Keep the departure timezone offset on the wire")
        let encoded = try JSONCoding.encoder.encode(groups[0].payload)
        let object = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        check((object["import_id"] as? String)?.count == 64,"Import identity must be stable for safe retries")
        check(object["import_id"] as? String == groups[0].id,"Rebuilding the same journey must retain its identity")
        check(!String(data:encoded,encoding:.utf8)!.contains("Frankfurt"),"Calendar titles and destination text stay on the phone")
        let saved = Trip(id:"saved",title:"",createdAt:"",legs:[FlightLeg(id:"leg",flightNumber:"LH 1189",departureDate:"2026-10-23",originIata:nil,destinationIata:nil,snapshot:nil)])
        check(CalendarFlightDetection.existingKeys([saved]).contains(flights[0].id),"Existing flight comparison uses canonical number and date")
        let long = (0..<10).map { n in
            CalendarFlight(flightNumber:"LH\(100+n)",destination:"City",departureDate:"2026-10-23",
                start:now.addingTimeInterval(Double(n)*7200),end:now.addingTimeInterval(Double(n)*7200+3600),timeZoneID:"UTC",calendarTitle:"Travel")
        }
        check(CalendarFlightDetection.journeys(from:long).map(\.flights.count) == [8,2],"Respect the server's maximum eight legs per trip")
        print("Calendar detection checks passed: airline titles, normalization, duplicates, timezone dates, connection boundaries, overlaps, request privacy and import identities.")
    }
}
