import Foundation

@main struct APIClientTests {
    static func expectURL(_ actual: URL, _ expected: String) {
        precondition(actual.absoluteString == expected,actual.absoluteString)
    }
    static func main() throws {
        let endpoints = [
            "/v1/server", "/v1/auth/register", "/v1/auth/login", "/v1/auth/logout",
            "/v1/auth/logout-all", "/v1/account", "/v1/account/api-key", "/v1/state",
            "/v1/usage", "/v1/usage/refresh", "/v1/trips", "/v1/trips/a-trip-id",
            "/v1/refresh?force=true&trip_id=a-trip-id"
        ]
        for address in ["https://192.0.2.10:8080/flights", "https://192.0.2.10:8080/flights/",
                        "192.0.2.10:8080/flights", "  HTTPS://192.0.2.10:8080/flights/\n"] {
            let client = try APIClient(address:address,token:"test-session")
            precondition(client.baseURL.absoluteString == "https://192.0.2.10:8080/flights")
            for endpoint in endpoints {
                let actual = try client.requestURL(endpoint)
                precondition(actual.absoluteString == "https://192.0.2.10:8080/flights"+endpoint,actual.absoluteString)
            }
        }
        for address in ["https://server.example.com", "https://server.example.com/"] {
            expectURL(try APIClient(address:address).requestURL("/v1/server"),"https://server.example.com/v1/server")
        }
        let nested = try APIClient(address:"https://server.example.com:9443/apps/flights/")
        expectURL(try nested.requestURL("/v1/state"),"https://server.example.com:9443/apps/flights/v1/state")
        let escaped = try APIClient(address:"https://server.example.com/flight%20deck/")
        expectURL(try escaped.requestURL("/v1/state"),"https://server.example.com/flight%20deck/v1/state")
        let ipv6 = try APIClient(address:"https://[2001:db8::1]:8080/flights")
        expectURL(try ipv6.requestURL("/v1/server"),"https://[2001:db8::1]:8080/flights/v1/server")
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let client = try APIClient(address:"http://\(host):18787/flights/")
            expectURL(try client.requestURL("/v1/server"),"http://\(host):18787/flights/v1/server")
        }
        for address in ["", "//server.example.com/flights", "ftp://server.example.com/flights",
                        "https://user:password@server.example.com/flights", "https://server.example.com/flights?q=1",
                        "https://server.example.com/flights#fragment", "https://server.example.com:0/flights",
                        "https://server.example.com:65536/flights", "https://server.example.com/flights/../other",
                        "https://server.example.com/flights/%2e%2e", "https://server.example.com/flights/%2fother",
                        "https://server.example.com/flights/%252e%252e", "https://server.example.com/flights/%5cother",
                        "https://server.example.com/flights/%00", "https://server.example.com/apps//flights"] {
            do { _ = try APIClient(address:address);fatalError("Accepted invalid address: \(address)") }
            catch ConnectionError.invalidURL { }
        }
        do { _ = try APIClient(address:"http://192.0.2.10:8080/flights");fatalError("Accepted remote HTTP") }
        catch ConnectionError.insecureURL { }
        for endpoint in ["https://other.example.com/v1/state", "//other.example.com/v1/state", "/health",
                         "/v1/../../other", "/v1/%2e%2e/other", "/v1/%2fother", "/v1/%252fother",
                         "/v1//state", "/v1/state#fragment"] {
            do { _ = try nested.requestURL(endpoint);fatalError("Accepted invalid API path: \(endpoint)") }
            catch ConnectionError.invalidURL { }
        }
        print("API URL checks passed: prefixed and root servers, ports, HTTPS defaults, IPv6, query preservation and path isolation.")
    }
}
