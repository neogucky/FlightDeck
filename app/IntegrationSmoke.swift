import Foundation

@main struct IntegrationSmoke {
    static func main() async throws {
        for address in ["http://localhost:18787", "http://localhost:18787/flights/"] {
            try await exercise(address:address)
        }
    }
    static func exercise(address: String) async throws {
        let publicAPI = try APIClient(address:address)
        let info = try await publicAPI.send("/v1/server",as:ServerInfo.self)
        precondition(info.protocolVersion == 2)
        let username = "smoke-"+UUID().uuidString.prefix(12).lowercased()
        let credentials = try JSONCoding.encoder.encode(LoginInput(username:username,password:"Native test-only password"))
        let auth = try await publicAPI.send("/v1/auth/register",method:"POST",body:credentials,as:AuthSession.self)
        let api = try APIClient(address:address,token:auth.sessionToken)
        let original = try await api.request("/v1/state")
        precondition(original.account?.id == auth.account.id && original.account?.hasApiKey == false)
        let configured = try await api.request("/v1/account/api-key",method:"PUT",body:JSONCoding.encoder.encode(KeyInput(apiKey:"flightdeck-test-native-key-"+username)))
        precondition(configured.account?.hasApiKey == true)
        let legs = [NewLeg(flightNumber:" lh 2055 "),NewLeg(flightNumber:"LX 1107")]
        let state = try await api.request("/v1/trips",method:"POST",body:JSONCoding.encoder.encode(NewTrip(title:"Native API check",legs:legs)))
        guard let trip = state.trips.first else { fatalError("Trip missing") }
        precondition(trip.legs.count == 2 && trip.legs[1].origin == "MUC")
        precondition(trip.legs[0].flightNumber == "LH2055" && trip.legs[1].flightNumber == "LX1107")
        precondition(trip.legs[0].origin == "HAM" && trip.legs[1].destination == "ZRH")
        precondition(trip.legs[0].snapshot?.flight.aircraftName == "Airbus A320neo")
        let report = try await api.send("/v1/usage",as:UsageReport.self)
        precondition(report.usage.reservedUsd == 0.02 && report.history.first?.requestCount == 2)
        let loggedIn = try await publicAPI.send("/v1/auth/login",method:"POST",body:credentials,as:AuthSession.self)
        let restored = try APIClient(address:address,token:loggedIn.sessionToken)
        let restoredState = try await restored.request("/v1/state")
        precondition(restoredState.trips.first?.id == trip.id)
        let secondCredentials = try JSONCoding.encoder.encode(LoginInput(username:username+"-b",password:"Another native test password"))
        let other = try await publicAPI.send("/v1/auth/register",method:"POST",body:secondCredentials,as:AuthSession.self)
        let otherAPI = try APIClient(address:address,token:other.sessionToken)
        let otherState = try await otherAPI.request("/v1/state")
        precondition(otherState.trips.isEmpty && otherState.usage?.requestCount == 0)
        let deleted = try await api.request("/v1/trips/\(trip.id)",method:"DELETE")
        precondition(deleted.trips.isEmpty)
        try await api.perform("/v1/auth/logout-all")
        do { _ = try await restored.request("/v1/state");fatalError("Revoked session accepted") }
        catch ConnectionError.unauthorized { }
        try await otherAPI.perform("/v1/auth/logout")
        print("Native API smoke passed at \(address): discovery, registration/login, write-only key setup, flight data, isolated usage/history, account isolation and session revocation.")
    }
}
