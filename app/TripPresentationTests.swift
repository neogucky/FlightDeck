import Foundation

@main
enum TripPresentationTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(),message)
    }
    static func main() {
        for number in ["LX1055", "LX 1055", " lx\t1055\n", "LX\u{00A0}1055"] {
            expect(number.canonicalFlightNumber == "LX1055","Whitespace must not change the flight identifier")
            let encoded = try! JSONCoding.encoder.encode(NewLeg(flightNumber:number))
            let json = try! JSONSerialization.jsonObject(with:encoded) as! [String:Any]
            expect(json["flight_number"] as? String == "LX1055","The wire identifier must be canonical")
            expect(json["origin_iata"] == nil && json["destination_iata"] == nil,"Airports come from the lookup")
        }
        let baseline = DemoData.trips()[0]
        checkAircraftReadiness(baseline.legs[0])
        var tracked=baseline.legs[0]
        tracked.snapshot?.fetchedAt=FlightTime.iso(Date().addingTimeInterval(-45*60))
        tracked.automaticRefreshIntervalSeconds=7200
        expect(!tracked.isDataStale,"A 45-minute-old flight is within the two-hour refresh interval")
        tracked.automaticRefreshIntervalSeconds=900
        expect(tracked.isDataStale,"The same data is stale inside the six-hour tracking window")
        tracked.automaticRefreshIntervalSeconds=0
        expect(!tracked.isDataStale,"Paused automatic tracking has no update deadline")
        var freshness=baseline
        freshness.legs[0].snapshot?.fetchedAt="2026-10-22T12:00:00Z"
        freshness.legs[1].snapshot?.fetchedAt="2026-10-22T12:05:00Z"
        expect(freshness.dataUpdatedAt==FlightTime.date("2026-10-22T12:00:00Z"),"Trip freshness must represent the oldest flight data, not the last server poll")
        freshness.legs[1].snapshot=nil
        expect(freshness.dataUpdatedAt==nil,"An incomplete trip must not claim all its details were updated")
        let oldUsage=Data(#"{"month":"2026-10","limit_usd":4.5,"hard_limit_usd":5,"reserved_usd":0.01,"provider_reported_usd":0.005,"conservative_used_usd":0.015,"remaining_usd":4.485,"request_count":1,"pricing_valid_until":"2026-11-18","blocked":false}"#.utf8)
        let compatible=try! JSONCoding.decoder.decode(Usage.self,from:oldUsage)
        expect(compatible.predictedPendingCosts==0.01,"An older server must remain readable during upgrade")
        expect(FlightTime.relative(FlightTime.date("2026-10-22T12:00:00Z")!,now:FlightTime.date("2026-10-22T12:00:39Z")!)=="39 seconds ago","Freshness should show seconds for recent updates")
        expect(baseline.status == JourneyStatus(label:"All on time"),"Both legs must be on time")

        var scheduled = baseline
        for i in scheduled.legs.indices {
            scheduled.legs[i].snapshot?.source = "schedule"
            scheduled.legs[i].snapshot?.flight.status = "Schedule only"
        }
        expect(scheduled.status.label == "Schedule only","A published schedule must never claim on-time live status")
        scheduled.legs[0] = baseline.legs[0]
        expect(scheduled.status.label == "Live status pending","One live leg cannot imply the whole trip has live status")

        var trip = baseline
        trip.legs[1].snapshot?.flight.departureDelayMinutes = 25
        expect(trip.status == JourneyStatus(label:"Flight delayed",warning:true),"A delayed connection must affect the trip")

        trip = baseline
        trip.legs[1].snapshot?.flight.arrivalDelayMinutes = 12
        expect(trip.status.warning,"Arrival delays must affect the trip even with an on-time departure")

        trip = baseline
        trip.legs[1].snapshot?.flight.cancelled = true
        expect(trip.status == JourneyStatus(label:"Flight cancelled",warning:true),"A cancelled connection must affect the trip")

        trip = baseline
        trip.legs[1].snapshot?.flight.diverted = true
        expect(trip.status == JourneyStatus(label:"Flight diverted",warning:true),"A diverted connection must affect the trip")

        trip = baseline
        trip.legs[1].snapshot = nil
        expect(trip.status.label == "Awaiting status","One known flight cannot imply the whole trip is on time")
        trip.legs[0].snapshot?.flight.departureDelayMinutes = 15
        expect(trip.status.warning,"A known problem must remain visible when another leg has no status")

        trip = baseline
        trip.legs[0].snapshot?.flight.actualArrival = baseline.legs[0].snapshot?.flight.scheduledArrival
        expect(trip.status.label == "Connecting","A completed first leg must retain the whole trip context")
        trip.legs[1].snapshot?.flight.actualDeparture = baseline.legs[1].snapshot?.flight.scheduledDeparture
        expect(trip.status.label == "In progress","A connection in the air must keep the trip in progress")
        trip.legs[1].snapshot?.flight.actualArrival = baseline.legs[1].snapshot?.flight.scheduledArrival
        expect(trip.status.label == "Arrived","Only a fully completed trip is arrived")

        trip = baseline
        trip.legs = [trip.legs[0]]
        expect(trip.status.label == "On time","Direct flights must still work")
        trip.legs = []
        expect(trip.status.label == "Awaiting status","An empty trip must not imply success")
        print("Trip presentation checks passed: status considers all legs, missing data, connections and completion.")
    }

    static func checkAircraftReadiness(_ baseline: FlightLeg) {
        let now=FlightTime.date("2026-10-22T12:00:00Z")!
        var leg=baseline
        leg.snapshot?.inbound?.actualArrival=FlightTime.iso(now.addingTimeInterval(-119*60))
        expect(leg.readyAircraftAirport(at:now)==nil,"A recently arrived flight must remain visible")
        leg.snapshot?.inbound?.actualArrival=FlightTime.iso(now.addingTimeInterval(-2*3600))
        expect(leg.readyAircraftAirport(at:now)==nil,"Keep the incoming flight through the exact two-hour boundary")
        leg.snapshot?.inbound?.actualArrival=FlightTime.iso(now.addingTimeInterval(-2*3600-1))
        expect(leg.readyAircraftAirport(at:now)?.iata=="HAM","An assigned plane that arrived over two hours ago is ready at the departure airport")
        let ready=leg

        leg.snapshot?.inbound?.actualArrival=nil
        leg.snapshot?.inbound?.estimatedArrival=FlightTime.iso(now.addingTimeInterval(-3*3600))
        expect(leg.readyAircraftAirport(at:now)==nil,"An old estimate is not a confirmed landing")
        leg=ready;leg.snapshot?.inbound?.actualArrival=FlightTime.iso(now.addingTimeInterval(60))
        expect(leg.readyAircraftAirport(at:now)==nil,"A future arrival cannot mark the plane ready")
        leg=ready;leg.snapshot?.inbound?.destination.iata="ZRH"
        expect(leg.readyAircraftAirport(at:now)==nil,"The aircraft must have arrived at this flight's departure airport")
        leg=ready;leg.snapshot?.inbound?.registration="OTHER"
        expect(leg.readyAircraftAirport(at:now)==nil,"An old flight of a different plane cannot mark the assigned aircraft ready")
        leg=ready;leg.snapshot?.flight.inboundProviderId="new-assignment"
        expect(leg.readyAircraftAirport(at:now)==nil,"A replaced incoming-flight assignment must not show the old plane as ready")
        leg=ready;leg.snapshot?.inbound?.diverted=true
        expect(leg.readyAircraftAirport(at:now)==nil,"A diverted arrival does not confirm the departure airport")
        leg=ready;leg.snapshot?.inbound?.cancelled=true
        expect(leg.readyAircraftAirport(at:now)==nil,"A cancelled incoming flight cannot confirm arrival")
        leg=ready;leg.snapshot?.flight.actualDeparture=FlightTime.iso(now)
        expect(leg.readyAircraftAirport(at:now)==nil,"An already departed flight must not say its plane is waiting at the airport")
        leg=ready;leg.snapshot?.source="schedule"
        expect(leg.readyAircraftAirport(at:now)==nil,"A published schedule cannot confirm a parked plane")

        leg=ready;leg.snapshot?.flight.registration=nil;leg.snapshot?.inbound?.registration=nil
        expect(leg.readyAircraftAirport(at:now)==nil,"An unverified plane must not be called ready")
        leg.snapshot?.flight.inboundProviderId="confirmed-inbound"
        leg.snapshot?.inbound?.providerId="confirmed-inbound"
        expect(leg.readyAircraftAirport(at:now)?.iata=="HAM","A confirmed provider assignment works even without a registration")
        leg.snapshot?.inbound?.actualArrival="2026-10-22T11:59:59+02:00"
        expect(leg.readyAircraftAirport(at:now)?.iata=="HAM","The two-hour cutoff must compare instants across timezones")
        expect(baseline.readyAircraftAirport(at:now)==nil,"An aircraft still en route keeps its incoming-flight card")
    }
}
