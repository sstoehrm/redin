package bridge

// #233 M1: the SSRF whitelist name-check and DNS resolution must run on the
// *same* bare host. Previously the name-check used a hand-rolled parser
// (url_host) while resolution used odin-http's parsed_url.host raw — two
// parsers that can disagree on the authority, so a URL could name-match a
// whitelisted host yet dial the IP resolved from a different one. Both paths
// now normalize the single parsed authority via authority_host; these tests
// pin that normalization, including the odin-http quirk that leaves a
// fragment inside `host`.

import http "lib:odin-http"
import "core:testing"

@(test)
test_authority_host_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, authority_host("example.com"), "example.com")
}

@(test)
test_authority_host_strips_port :: proc(t: ^testing.T) {
	testing.expect_value(t, authority_host("example.com:8080"), "example.com")
}

@(test)
test_authority_host_strips_userinfo :: proc(t: ^testing.T) {
	testing.expect_value(t, authority_host("user:pass@example.com"), "example.com")
	testing.expect_value(t, authority_host("user@169.254.169.254"), "169.254.169.254")
}

@(test)
test_authority_host_ipv6_brackets :: proc(t: ^testing.T) {
	testing.expect_value(t, authority_host("[::1]:8080"), "::1")
	testing.expect_value(t, authority_host("[2001:db8::1]"), "2001:db8::1")
}

@(test)
test_authority_host_strips_fragment :: proc(t: ^testing.T) {
	// odin-http's url_parse leaves a '#fragment' inside host; the bare host
	// is what precedes it.
	testing.expect_value(t, authority_host("example.com#@169.254.169.254"), "example.com")
}

@(test)
test_authority_port :: proc(t: ^testing.T) {
	testing.expect_value(t, authority_port("example.com:8080"), 8080)
	testing.expect_value(t, authority_port("example.com"), 0)
	testing.expect_value(t, authority_port("[::1]:443"), 443)
	testing.expect_value(t, authority_port("user@host:1234"), 1234)
	// A ':N' living inside the fragment must not be read as a port.
	testing.expect_value(t, authority_port("example.com#x:9"), 0)
}

// The core invariant: the bare host we derive for the whitelist / resolve is
// taken from odin-http's own parse of the URL, so name-check and dial can
// never target different hosts. For the fragment-injection URL, the derived
// host is the benign prefix, NOT the injected internal address.
@(test)
test_parsed_authority_matches_security_host :: proc(t: ^testing.T) {
	cases := []struct {
		url:  string,
		want: string,
	}{
		{"http://example.com/path", "example.com"},
		{"http://example.com:8080/path?q=1", "example.com"},
		{"http://user@example.com/", "example.com"},
		{"http://[::1]:80/", "::1"},
		// Fragment injection: we must resolve/dial example.com, not the
		// internal metadata address hidden after the '#'.
		{"http://example.com#@169.254.169.254/", "example.com"},
	}
	for c in cases {
		parsed := http.url_parse(c.url)
		got := authority_host(parsed.host)
		testing.expectf(t, got == c.want, "url %q: got host %q, want %q", c.url, got, c.want)
	}
}
