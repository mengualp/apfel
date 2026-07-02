// ServerSecurityTests - pure server-hardening predicate tests
// Covers host classification (#228), exposed-without-token warning gate (#228),
// Host-header allowlisting (#230), and MCP env scrubbing (#229).

import ApfelCore

func runServerSecurityTests() {

    // MARK: - isLoopbackHost (#228)

    test("isLoopbackHost: 127.0.0.1 is loopback") {
        try assertTrue(ServerSecurity.isLoopbackHost("127.0.0.1"))
    }

    test("isLoopbackHost: localhost is loopback (case-insensitive)") {
        try assertTrue(ServerSecurity.isLoopbackHost("localhost"))
        try assertTrue(ServerSecurity.isLoopbackHost("LocalHost"))
    }

    test("isLoopbackHost: ::1 and [::1] are loopback") {
        try assertTrue(ServerSecurity.isLoopbackHost("::1"))
        try assertTrue(ServerSecurity.isLoopbackHost("[::1]"))
    }

    test("isLoopbackHost: 0.0.0.0 is NOT loopback") {
        try assertTrue(!ServerSecurity.isLoopbackHost("0.0.0.0"))
    }

    test("isLoopbackHost: LAN address is NOT loopback") {
        try assertTrue(!ServerSecurity.isLoopbackHost("192.168.1.10"))
    }

    // MARK: - shouldWarnExposedWithoutToken (#228)

    test("exposed warning: 0.0.0.0 without token warns") {
        try assertTrue(ServerSecurity.shouldWarnExposedWithoutToken(host: "0.0.0.0", hasToken: false))
    }

    test("exposed warning: 0.0.0.0 WITH token does not warn") {
        try assertTrue(!ServerSecurity.shouldWarnExposedWithoutToken(host: "0.0.0.0", hasToken: true))
    }

    test("exposed warning: loopback without token does not warn") {
        try assertTrue(!ServerSecurity.shouldWarnExposedWithoutToken(host: "127.0.0.1", hasToken: false))
        try assertTrue(!ServerSecurity.shouldWarnExposedWithoutToken(host: "localhost", hasToken: false))
    }

    test("exposed warning: LAN bind without token warns") {
        try assertTrue(ServerSecurity.shouldWarnExposedWithoutToken(host: "192.168.1.10", hasToken: false))
    }
}
