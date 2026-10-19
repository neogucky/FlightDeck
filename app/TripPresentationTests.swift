import Foundation

@main
enum TripPresentationTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(),message)
    }
    static func main() {
        let baseline = DemoData.trips()[0]
        expect(baseline.status == JourneyStatus(label:"All on time"),"Both legs must be on time")

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
}
