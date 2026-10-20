import Foundation
import Security

enum ConnectionError: LocalizedError {
    case invalidURL, unauthorized, response(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS server address without a path, query, or embedded credentials."
        case .unauthorized: "Your session has expired. Sign in again in Settings."
        case .response(let message): message
        }
    }
}

enum TokenVault {
    private static let service = "com.flightdeck.connection"
    private static var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"session"]
    }
    static func readSession() -> SavedSession? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONCoding.decoder.decode(SavedSession.self,from:data)
    }
    static func saveSession(_ session: SavedSession) throws {
        let data = try JSONCoding.encoder.encode(session)
        let update = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ConnectionError.response("The session could not be saved securely (Keychain \(update)).") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary,nil)
        guard added == errSecSuccess else { throw ConnectionError.response("The session could not be saved securely (Keychain \(added)).") }
    }
    static func clear() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw ConnectionError.response("The saved session could not be removed. Try signing out again.") }
        // Remove the former shared-server token during this upgrade.
        var legacy = query; legacy[kSecAttrAccount as String] = "token"
        SecItemDelete(legacy as CFDictionary)
    }
}

struct APIClient {
    let baseURL: URL
    let token: String
    init(address: String, token: String = "") throws {
        guard let url = URL(string:address.trimmingCharacters(in:.whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost","127.0.0.1","::1"].contains(host)) else {
            throw ConnectionError.invalidURL
        }
        self.baseURL = url; self.token = token
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> ServerState {
        try await send(path,method:method,body:body,as:ServerState.self)
    }
    func send<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, as type: T.Type) async throws -> T {
        let data = try await data(path,method:method,body:body)
        return try JSONCoding.decoder.decode(type,from:data)
    }
    func perform(_ path: String, method: String = "POST") async throws {
        _ = try await data(path,method:method,body:nil)
    }
    private func data(_ path: String, method: String, body: Data?) async throws -> Data {
        guard path.hasPrefix("/v1/"), !path.hasPrefix("//"),let url = URL(string:path,relativeTo:baseURL),
              url.host == baseURL.host, url.scheme == baseURL.scheme, url.port == baseURL.port else { throw ConnectionError.invalidURL }
        var req = URLRequest(url:url); req.httpMethod = method; req.timeoutInterval = 60
        if !token.isEmpty { req.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization") }
        req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody = body
        let session = URLSession(configuration:.ephemeral,delegate:NoRedirects(),delegateQueue:nil)
        defer { session.finishTasksAndInvalidate() }
        let (data,response) = try await session.data(for:req)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.response("Unexpected server response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 && !token.isEmpty { throw ConnectionError.unauthorized }
            struct Failure: Decodable { var detail: String? }
            let message = (try? JSONDecoder().decode(Failure.self,from:data))?.detail
            throw ConnectionError.response(message ?? "The server returned an error (\(http.statusCode)). Please try again.")
        }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
