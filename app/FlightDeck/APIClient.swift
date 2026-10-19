import Foundation
import Security

enum ConnectionError: LocalizedError {
    case invalidURL, missingToken, response(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS server address without a path, query, or embedded credentials."
        case .missingToken: "Enter your server’s connection token."
        case .response(let message): message
        }
    }
}

enum TokenVault {
    private static let service = "com.flightdeck.connection"
    static func read() -> String {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
                              kSecAttrAccount as String:"token", kSecReturnData as String:true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data:data, encoding:.utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"token"]
        let update = SecItemUpdate(q as CFDictionary,[kSecValueData as String:Data(value.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ConnectionError.response("The connection token could not be saved securely.") }
        var item = q
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ConnectionError.response("The connection token could not be saved securely.")
        }
    }
}

struct APIClient {
    let baseURL: URL
    let token: String
    init(address: String, token: String) throws {
        guard let url = URL(string:address.trimmingCharacters(in:.whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost","127.0.0.1","::1"].contains(host)) else {
            throw ConnectionError.invalidURL
        }
        guard token.count >= 32 else { throw ConnectionError.missingToken }
        self.baseURL = url; self.token = token
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> ServerState {
        guard let url = URL(string: path, relativeTo:baseURL) else { throw ConnectionError.invalidURL }
        var req = URLRequest(url:url); req.httpMethod = method; req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
        req.setValue("application/json", forHTTPHeaderField:"Content-Type")
        req.httpBody = body
        let session = URLSession(configuration:.ephemeral,delegate:NoRedirects(),delegateQueue:nil)
        defer { session.finishTasksAndInvalidate() }
        let (data,response) = try await session.data(for:req)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.response("Unexpected server response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ConnectionError.response("Connection token not accepted. Check Settings.") }
            if http.statusCode == 422 {
                throw ConnectionError.response("Check the flight numbers, dates and airport codes. Connected legs must share an airport and be in date order.")
            }
            throw ConnectionError.response("The server returned an error (\(http.statusCode)). Saved flights are still available.")
        }
        return try JSONCoding.decoder.decode(ServerState.self, from:data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
