import Foundation

// Compile with FlightDeck/Models.swift and FlightDeck/APIClient.swift, while the
// local fixture server runs. Exercises the same client and Codable models as iOS.
@main struct IntegrationSmoke {
    static func main() async throws {
        let api = try APIClient(address:"http://localhost:18787",token:"flightdeck-local-integration-token-not-a-secret")
        let original = try await api.request("/v1/state")
        precondition(original.mode == "demo")
        let legs = [NewLeg(flightNumber:"LH2055",originIata:"HAM",destinationIata:"MUC"),
                    NewLeg(flightNumber:"LX1107",originIata:"MUC",destinationIata:"ZRH")]
        let state = try await api.request("/v1/trips",method:"POST",body:JSONCoding.encoder.encode(NewTrip(title:"Native API check",legs:legs)))
        guard let trip = state.trips.first(where:{$0.title == "Native API check"}) else { fatalError("Trip missing") }
        precondition(trip.legs.count == 2 && trip.legs[1].origin == "MUC")
        precondition(trip.legs[0].snapshot?.flight.aircraftName == "Airbus A320neo")
        let refreshed = try await api.request("/v1/refresh?force=true&trip_id=\(trip.id)",method:"POST")
        precondition(refreshed.usage?.reservedUsd == 0)
        precondition(refreshed.trips.count == original.trips.count+1)
        let deleted = try await api.request("/v1/trips/\(trip.id)",method:"DELETE")
        precondition(!deleted.trips.contains(where:{$0.id == trip.id}))
        print("Native API smoke passed: authentication, connected-trip encoding, snapshot decoding, refresh, budget and deletion.")
    }
}
