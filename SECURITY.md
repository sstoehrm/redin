# Security policy

## Supported versions

Only the latest release receives security fixes. redin is pre-1.0, so fixes
ship in a new release rather than as backports.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
**[Report a vulnerability](https://github.com/sstoehrm/redin/security/advisories/new)**
(the Security tab of this repository). Do not open a public issue.

Include the affected version or commit, how to reproduce it, and the impact
you expect.

## What to expect

This is a single-maintainer project; handling is best effort. I aim to
acknowledge a report within a week, agree on a fix and a disclosure date with
you, and publish a GitHub security advisory once a fixed release is out. You
are credited in the advisory unless you ask not to be.

## Scope

The release binary deliberately runs an authenticated control server on
loopback; any process running as your own user can drive it. That is the
documented security model (see the [Security section of the README](README.md#security)
and the [Dev Server reference](docs/reference/dev-server.md#runtime-caveats)),
not a vulnerability. Ways around it — reaching the server from another user
or another host, bypassing the token or `Host` check, or escaping the HTTP
whitelist — are in scope.
