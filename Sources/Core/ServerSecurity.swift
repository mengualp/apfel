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

    /// Minimal environment handed to a local (stdio) MCP subprocess (#229).
    ///
    /// A `Process` with `environment == nil` inherits apfel's entire environment,
    /// leaking `APFEL_TOKEN`/`APFEL_MCP_TOKEN` and any cloud/API keys in the shell
    /// to the third-party tool script. This returns an explicit allowlist instead:
    /// PATH/HOME/TMPDIR/LANG plus `LC_*`, `PYTHON*`, and `VIRTUAL_ENV` (what the
    /// calculator server and typical FastMCP/venv servers need). Everything else
    /// is dropped, and any `APFEL_*` var or any var whose name contains
    /// TOKEN/KEY/SECRET is excluded even if it would otherwise match. PATH is
    /// synthesized when absent so `/usr/bin/env python3` still resolves.
    public static func scrubbedMCPEnvironment(from parent: [String: String]) -> [String: String] {
        let exactAllow: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "VIRTUAL_ENV"]
        let prefixAllow = ["LC_", "PYTHON"]
        var result: [String: String] = [:]
        for (key, value) in parent {
            let upper = key.uppercased()
            // Exclusions win over the allowlist.
            if upper.hasPrefix("APFEL_") { continue }
            if upper.contains("TOKEN") || upper.contains("KEY") || upper.contains("SECRET") { continue }
            if exactAllow.contains(upper) || prefixAllow.contains(where: { upper.hasPrefix($0) }) {
                result[key] = value
            }
        }
        if result["PATH"] == nil {
            result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return result
    }
}
