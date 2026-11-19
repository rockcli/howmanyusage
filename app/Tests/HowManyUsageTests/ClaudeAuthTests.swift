import Foundation
import Testing
@testable import HowManyUsage

struct ClaudeAuthTests {
    @Test func parsesCliCredentialFallbackShape() throws {
        let raw = """
        {"claudeAiOauth":{"accessToken":"access","refreshToken":"refresh",
        "expiresAt":1793000000000,"subscriptionType":"max","rateLimitTier":"default"}}
        """
        let tokens = try Auth.parseClaudeTokens(raw)
        #expect(tokens.accessToken == "access")
        #expect(tokens.subscriptionType == "max")
        #expect(tokens.expiresAt.timeIntervalSince1970 == 1_793_000_000)
    }

    @Test func rejectsCredentialsWithoutOAuthTokens() {
        #expect(throws: AuthError.self) {
            try Auth.parseClaudeTokens(#"{"claudeAiOauth":{"accessToken":"access"}}"#)
        }
    }
}
