import Foundation

enum DemoData {
    static func trips() -> [Trip] {
        let now = Date()
        let day = Calendar.current.startOfDay(for:now)
        let start = max(now.addingTimeInterval(75*60), day.addingTimeInterval(10*3600))
        let airports: [String:Airport] = [
            "HAM":Airport(iata:"HAM",name:"Hamburg Airport",city:"Hamburg",timezone:"Europe/Berlin"),
            "MUC":Airport(iata:"MUC",name:"Munich Airport",city:"Munich",timezone:"Europe/Berlin"),
            "ZRH":Airport(iata:"ZRH",name:"Zurich Airport",city:"Zurich",timezone:"Europe/Zurich"),
            "LHR":Airport(iata:"LHR",name:"Heathrow Airport",city:"London",timezone:"Europe/London"),
            "CPT":Airport(iata:"CPT",name:"Cape Town International",city:"Cape Town",timezone:"Africa/Johannesburg"),
            "JNB":Airport(iata:"JNB",name:"O.R. Tambo International",city:"Johannesburg",timezone:"Africa/Johannesburg")]
        func flight(_ number: String, _ origin: String, _ dest: String, _ date: Date, _ duration: Double, past: Bool = false) -> FlightInfo {
            FlightInfo(providerId:"demo-\(number)",flightNumber:number,origin:airports[origin]!,destination:airports[dest]!,
                status:past ? "Arrived":"Scheduled",cancelled:false,diverted:false,registration:"D-AINQ",aircraftType:"A20N",operator:"LH",
                scheduledDeparture:FlightTime.iso(date),estimatedDeparture:FlightTime.iso(date),actualDeparture:past ? FlightTime.iso(date):nil,
                scheduledArrival:FlightTime.iso(date.addingTimeInterval(duration*60)),estimatedArrival:FlightTime.iso(date.addingTimeInterval(duration*60)),
                actualArrival:past ? FlightTime.iso(date.addingTimeInterval(duration*60)):nil,departureGate:"A24",arrivalGate:"G18",departureTerminal:"2",arrivalTerminal:"2",
                arrivalDelayMinutes:0,departureDelayMinutes:0,progress:past ? 100:0,inboundProviderId:nil)
        }
        func leg(_ f: FlightInfo, inbound: FlightInfo? = nil) -> FlightLeg {
            FlightLeg(id:UUID().uuidString,flightNumber:f.flightNumber,departureDate:FlightTime.day(FlightTime.date(f.scheduledDeparture)!),
                originIata:f.origin.iata,destinationIata:f.destination.iata,
                snapshot:FlightSnapshot(fetchedAt:FlightTime.iso(now.addingTimeInterval(-120)),flight:f,inbound:inbound,
                    inboundNote:inbound == nil ? "Incoming aircraft not yet confirmed.":nil))
        }
        var inbound = flight("LH2052","MUC","HAM",start.addingTimeInterval(-115*60),75)
        inbound.actualDeparture = inbound.scheduledDeparture; inbound.status = "En Route"; inbound.progress = 68
        let first = leg(flight("LH2055","HAM","MUC",start,80),inbound:inbound)
        var secondInfo = flight("LX1107","MUC","ZRH",start.addingTimeInterval(140*60),55)
        secondInfo.registration = "HB-JDB"; secondInfo.departureGate = "G28"; secondInfo.operator = "LX"
        let second = leg(secondInfo)
        let next = leg(flight("LX318","ZRH","LHR",day.addingTimeInterval(5*86400+11*3600),105))
        let past = leg(flight("FA104","CPT","JNB",day.addingTimeInterval(-8*86400+9*3600),125,past:true))
        return [Trip(id:UUID().uuidString,title:"A weekend in Zurich",createdAt:FlightTime.iso(now),legs:[first,second]),
                Trip(id:UUID().uuidString,title:"London calling",createdAt:FlightTime.iso(now),legs:[next]),
                Trip(id:UUID().uuidString,title:"Back to Johannesburg",createdAt:FlightTime.iso(now),legs:[past])]
    }
}
