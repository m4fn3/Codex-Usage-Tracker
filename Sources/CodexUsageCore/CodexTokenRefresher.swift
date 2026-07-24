//
//  CodexTokenRefresher.swift
//  Codex Usage Tracker
//
//  Refreshes a ChatGPT OAuth access token from its refresh token. Needed because
//  only the active account's token is kept fresh by the CLI; to show an INACTIVE
//  account's usage (or to switch to it) we may have to refresh its token ourselves.
//
//    POST https://auth.openai.com/oauth/token
//    Content-Type: application/x-www-form-urlencoded
//    grant_type=refresh_token&refresh_token=<...>&client_id=app_EMoamEEZ73f0CkXaXp7hrann
//
//  (Same endpoint/params as the Codex CLI and codex-switcher.)
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexTokenRefreshError: Error, Sendable {
    case missingRefreshToken
    case http(Int)
    case invalidResponse
    case transport(String)
}

public enum CodexTokenRefresher {

    static let issuer = "https://auth.openai.com"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// Refreshes the given account's tokens and returns a fresh auth identity.
    public static func refresh(
        account: CodexAccount,
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> CodexAuth {
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            throw CodexTokenRefreshError.missingRefreshToken
        }
        return try await refresh(
            refreshToken: refreshToken,
            accountId: account.id,
            now: now,
            session: session
        )
    }

    public static func refresh(
        refreshToken: String,
        accountId: String?,
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> CodexAuth {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = "grant_type=refresh_token"
            + "&refresh_token=\(formEncode(refreshToken))"
            + "&client_id=\(formEncode(clientID))"
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexTokenRefreshError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CodexTokenRefreshError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw CodexTokenRefreshError.http(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              !decoded.accessToken.isEmpty else {
            throw CodexTokenRefreshError.invalidResponse
        }

        return CodexAuth.from(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? refreshToken,
            idToken: decoded.idToken,
            accountIdFallback: accountId
        )
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    struct Response: Decodable {
        let accessToken: String
        let idToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case refreshToken = "refresh_token"
        }
    }
}
