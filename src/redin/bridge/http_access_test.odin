package bridge

// #162 M3: SSRF hardening for redin.http. The whitelist now carries an
// access *class* keyword — "all" / "local" / "external" — that classifies
// the *resolved* IP, so a public hostname that resolves to a loopback or
// private address is caught (DNS-rebinding defence). Explicit hostname /
// CIDR entries still allow on top of the class. These tests cover the
// pure pieces: IP classification and the access decision.

import "core:net"
import "core:testing"

// --- IP classification ---

@(test)
test_ip_is_loopback :: proc(t: ^testing.T) {
	v4_lo, _ := net.parse_ip4_address("127.0.0.1")
	v4_lo2, _ := net.parse_ip4_address("127.255.255.254")
	v4_pub, _ := net.parse_ip4_address("8.8.8.8")
	testing.expect(t, ip4_is_loopback(v4_lo), "127.0.0.1 is loopback")
	testing.expect(t, ip4_is_loopback(v4_lo2), "127/8 is loopback")
	testing.expect(t, !ip4_is_loopback(v4_pub), "8.8.8.8 is not loopback")

	v6_lo, _ := net.parse_ip6_address("::1")
	v6_pub, _ := net.parse_ip6_address("2001:4860:4860::8888")
	testing.expect(t, ip6_is_loopback(v6_lo), "::1 is loopback")
	testing.expect(t, !ip6_is_loopback(v6_pub), "public v6 is not loopback")
}

@(test)
test_ip4_is_private :: proc(t: ^testing.T) {
	for s in ([]string{"10.0.0.1", "172.16.5.4", "172.31.255.1", "192.168.1.1",
	                    "169.254.169.254", "127.0.0.1"}) {
		a, ok := net.parse_ip4_address(s)
		testing.expect(t, ok, "parse")
		testing.expectf(t, ip4_is_private_or_local(a), "%s should classify as private/local", s)
	}
	for s in ([]string{"8.8.8.8", "1.1.1.1", "172.32.0.1", "192.169.0.1", "11.0.0.1"}) {
		a, ok := net.parse_ip4_address(s)
		testing.expect(t, ok, "parse")
		testing.expectf(t, !ip4_is_private_or_local(a), "%s should classify as external", s)
	}
}

@(test)
test_ip6_is_private :: proc(t: ^testing.T) {
	for s in ([]string{"::1", "fe80::1", "fc00::1", "fd12:3456::1"}) {
		a, ok := net.parse_ip6_address(s)
		testing.expect(t, ok, "parse")
		testing.expectf(t, ip6_is_private_or_local(a), "%s should classify as private/local", s)
	}
	for s in ([]string{"2001:4860:4860::8888", "2606:4700::1111"}) {
		a, ok := net.parse_ip6_address(s)
		testing.expect(t, ok, "parse")
		testing.expectf(t, !ip6_is_private_or_local(a), "%s should classify as external", s)
	}
}

// --- access decision ---

@(test)
test_access_class_parse :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_access_class("all"), Access_Class.All)
	testing.expect_value(t, parse_access_class("*"), Access_Class.All)   // back-compat alias
	testing.expect_value(t, parse_access_class("local"), Access_Class.Local)
	testing.expect_value(t, parse_access_class("external"), Access_Class.External)
	testing.expect_value(t, parse_access_class("example.com"), Access_Class.None) // not a class keyword
}

@(test)
test_access_decide_all :: proc(t: ^testing.T) {
	lo, _ := net.parse_ip4_address("127.0.0.1")
	pub, _ := net.parse_ip4_address("8.8.8.8")
	testing.expect(t, access_decide_ip4(.All, lo), "all allows loopback")
	testing.expect(t, access_decide_ip4(.All, pub), "all allows external")
}

@(test)
test_access_decide_local :: proc(t: ^testing.T) {
	lo, _ := net.parse_ip4_address("127.0.0.1")
	priv, _ := net.parse_ip4_address("10.0.0.1")
	pub, _ := net.parse_ip4_address("8.8.8.8")
	testing.expect(t, access_decide_ip4(.Local, lo), "local allows loopback")
	testing.expect(t, !access_decide_ip4(.Local, priv), "local denies RFC1918")
	testing.expect(t, !access_decide_ip4(.Local, pub), "local denies external")
}

@(test)
test_access_decide_external :: proc(t: ^testing.T) {
	lo, _ := net.parse_ip4_address("127.0.0.1")
	priv, _ := net.parse_ip4_address("192.168.1.1")
	meta, _ := net.parse_ip4_address("169.254.169.254")
	pub, _ := net.parse_ip4_address("8.8.8.8")
	testing.expect(t, !access_decide_ip4(.External, lo), "external denies loopback")
	testing.expect(t, !access_decide_ip4(.External, priv), "external denies RFC1918")
	testing.expect(t, !access_decide_ip4(.External, meta), "external denies metadata IP")
	testing.expect(t, access_decide_ip4(.External, pub), "external allows public")
}

@(test)
test_access_decide_none :: proc(t: ^testing.T) {
	pub, _ := net.parse_ip4_address("8.8.8.8")
	testing.expect(t, !access_decide_ip4(.None, pub), "no class set denies by default")
}
