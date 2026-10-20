import Foundation
import Security

enum ConnectionError: LocalizedError {
    case invalidURL, insecureURL, unauthorized, response(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid server address, such as https://server.example.com:8080/flights, without a query or embedded credentials."
        case .insecureURL: "Use HTTPS to protect your password, session and API key. HTTP is supported only for localhost development."
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
        let input = address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !input.isEmpty,!input.hasPrefix("//"),
              var parts = URLComponents(string:input.contains("://") ? input:"https://"+input),
              let host = parts.host,!host.isEmpty,
              host.rangeOfCharacter(from:.whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let scheme = parts.scheme?.lowercased(),["https","http"].contains(scheme),
              parts.user == nil,parts.password == nil,parts.query == nil,parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),Self.safePath(parts.percentEncodedPath) else {
            throw ConnectionError.invalidURL
        }
        let normalizedHost = host.lowercased()
        guard scheme == "https" || ["localhost","127.0.0.1","[::1]"].contains(normalizedHost) else {
            throw ConnectionError.insecureURL
        }
        parts.scheme = scheme;parts.host = normalizedHost
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw ConnectionError.invalidURL }
        self.baseURL = url;self.token = token
    }
    // Compose paths explicitly: resolving a leading /v1 path would discard a proxy prefix.
    func requestURL(_ path: String) throws -> URL {
        guard let route = URLComponents(string:path),route.scheme == nil,route.host == nil,
              route.user == nil,route.password == nil,route.fragment == nil,
              route.percentEncodedPath.hasPrefix("/v1/"),Self.safePath(route.percentEncodedPath),
              var parts = URLComponents(url:baseURL,resolvingAgainstBaseURL:false) else {
            throw ConnectionError.invalidURL
        }
        parts.percentEncodedPath += route.percentEncodedPath
        parts.percentEncodedQuery = route.percentEncodedQuery
        guard let url = parts.url,url.host == baseURL.host,url.scheme == baseURL.scheme,url.port == baseURL.port else {
            throw ConnectionError.invalidURL
        }
        return url
    }
    private static func safePath(_ path: String) -> Bool {
        guard !path.contains("//") else { return false }
        return path.split(separator:"/").allSatisfy { segment in
            guard let decoded = String(segment).removingPercentEncoding else { return false }
            return decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\") &&
                !decoded.contains("%") && decoded.rangeOfCharacter(from:.controlCharacters) == nil
        }
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
        let url = try requestURL(path)
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
