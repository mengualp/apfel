// ============================================================================
// ServerSecurity.swift - Pure server-hardening predicates (host classification,
// startup-warning gates, Host-header allowlisting, MCP env scrubbing).
// Lives in ApfelCore so it is unit-testable without Hummingbird or Foundation
// networking.
// ============================================================================

/// Pure decision logic for server security hardening. No I/O, no framework
/// dependencies - just predicates the CLI/server/MCP layers consult.
public enum ServerSecurity {

    /// True if `host` is a loopback bind address (traffic never leaves the box).
    public static func isLoopbackHost(_ host: String) -> Bool {
        switch host.lowercased() {
        case "127.0.0.1", "localhost", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    /// True when the server is bound to a non-loopback address with no bearer
    /// token: every host that can reach the socket can hit the inference
    /// endpoints with zero authentication (#228). Callers surface a loud warning.
    public static func shouldWarnExposedWithoutToken(host: String, hasToken: Bool) -> Bool {
        return !isLoopbackHost(host) && !hasToken
    }
}
