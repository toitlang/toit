// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
The network policy of a sandboxed container (experimental): which
  destinations it may connect to, and how much it may use the network.

This file is the whole policy decision and limiter of the sandbox network
  services (system/sandbox_network/): it does no I/O, and everything a
  sandbox can reach goes through $NetworkGrant.allows (before a name is
  resolved), $NetworkGrant.address-allowed (for the address the service
  resolved), $NetworkGrant.open-connection and $NetworkGrant.take-bytes.

The policy is given by whoever starts the container, as entry
  $POLICY-NETWORK-INDEX of the launch policy (see
  `containers.start --network`):

```
[rules, connections, attempts-per-minute, bytes-per-second, bytes-per-day,
 response-bytes, timeout-ms]
```

Each limit is an int; -1 (or a missing entry) means the default below.

A rule is a string `HOST:PORTS` or `HOST:PORTS/PATH`:
- HOST is a DNS name (`api.example.com`), a name with a wildcard first
  label (`*.example.com`, which matches `a.example.com` and
  `a.b.example.com` but not `example.com`), or an IPv4 address.
- PORTS is a port (`443`) or a range (`8000-8099`).
- PATH (optional, starting with `/`) only applies to HTTP requests
  (variant H): the request path must start with it. Rules with a PATH
  never allow sockets (variant S), because the service can't see what a
  socket client sends.

Addresses that aren't public (loopback, private, link-local, carrier-grade
  NAT, multicast, reserved; see $is-public-address) are only allowed if a
  rule names the address itself (an IPv4 HOST) and covers the port: a name
  that is allowed but resolves to such an address is denied.
*/

POLICY-NETWORK-INDEX ::= 11

MAX-RULES ::= 16
MAX-RULE-SIZE ::= 128
MAX-HOST-SIZE ::= 253

// Defaults and upper bounds of the limits, in the order of the policy list.
LIMIT-NAMES_ ::= ["connections", "attempts-per-minute", "bytes-per-second",
                  "bytes-per-day", "response-bytes", "timeout-ms"]
LIMIT-DEFAULTS_ ::= [2, 20, 16 * 1024, 10 * 1024 * 1024, 1024 * 1024, 30_000]
LIMIT-MIN_ ::= [1, 1, 1024, 1, 1, 100]
LIMIT-MAX_ ::= [8, 600, 1024 * 1024, 1 << 30, 1 << 30, 300_000]

class Rule_:
  host/string            // Lower case; a leading "*." for wildcards.
  ip/ByteArray?          // The address, if the host is an IPv4 address.
  from/int
  to/int
  path/string?

  constructor .host .ip .from .to .path:

  matches-host name/string -> bool:
    if host.starts-with "*.": return name.ends-with host[1..] and name.size > host.size - 1
    return name == host

  covers-port port/int -> bool:
    return from <= port <= to

  covers-path path-or-null/string? -> bool:
    if not path: return true
    if not path-or-null: return false  // Sockets: the service can't check.
    return path-or-null.starts-with path

class NetworkGrant:
  rules_/List
  max-connections/int
  attempts-per-minute/int
  bytes-per-second/int
  bytes-per-day/int
  response-bytes/int
  timeout-ms/int

  // Limiter state.
  connections_/int := 0
  attempt-credit-us_/int := ?  // At most one minute; an attempt costs 60 s / limit.
  attempt-time-us_/int := ?
  byte-credit_/int := ?        // In bytes * 1_000_000; at most one second of bytes.
  byte-time-us_/int := ?
  day-start-us_/int := ?
  day-bytes_/int := 0

  static DAY-US_ ::= 24 * 3600 * 1_000_000

  /**
  Parses the network entry of a launch policy. Throws INVALID_ARGUMENT or
    WRONG_OBJECT_TYPE if it is malformed. The result is kept in the system
    process while the container lives; its size is bounded by $MAX-RULES
    and $MAX-RULE-SIZE.
  */
  constructor policy/any:
    if policy is not List or policy.is-empty or policy.size > 1 + LIMIT-NAMES_.size:
      throw "INVALID_ARGUMENT"
    rules := policy[0]
    if rules is not List: throw "WRONG_OBJECT_TYPE"
    if rules.size > MAX-RULES: throw "INVALID_ARGUMENT"
    rules_ = rules.map: parse-rule_ it
    limits := List LIMIT-NAMES_.size: | i |
      value := i + 1 < policy.size ? policy[i + 1] : -1
      if value is not int: throw "WRONG_OBJECT_TYPE"
      if value == -1:
        LIMIT-DEFAULTS_[i]
      else:
        if not LIMIT-MIN_[i] <= value <= LIMIT-MAX_[i]: throw "INVALID_ARGUMENT"
        value
    max-connections = limits[0]
    attempts-per-minute = limits[1]
    bytes-per-second = limits[2]
    bytes-per-day = limits[3]
    response-bytes = limits[4]
    timeout-ms = limits[5]
    now := Time.monotonic-us
    attempt-credit-us_ = 60_000_000
    attempt-time-us_ = now
    byte-credit_ = bytes-per-second * 1_000_000
    byte-time-us_ = now
    day-start-us_ = now

  /**
  Whether a rule allows connecting to $host (a name or an IPv4 address, as
    the client gave it) at $port; for HTTP requests $path is the request
    path, for sockets null. This is decided before the name is resolved.
  */
  allows host/string port/int --path/string? -> bool:
    if not is-valid-host_ host: return false
    if path and not is-plain-path_ path: return false
    name := host.to-ascii-lower
    return rules_.any: | rule/Rule_ |
      (rule.matches-host name) and (rule.covers-port port) and (rule.covers-path path)

  /**
  Whether the service may connect to the $address (4 bytes) at $port that
    it resolved for an allowed name: public addresses are allowed, others
    only if a rule names them.
  */
  address-allowed address/ByteArray port/int -> bool:
    if address.size != 4: return false
    if is-public-address address: return true
    return rules_.any: | rule/Rule_ |
      rule.ip == address and (rule.covers-port port)

  /**
  Takes a connection: throws QUOTA_EXCEEDED if the container has
    $max-connections open or tried more than $attempts-per-minute times in
    the last minute. Every call counts as an attempt.
  */
  open-connection -> none:
    now := Time.monotonic-us
    attempt-credit-us_ = min 60_000_000 (attempt-credit-us_ + now - attempt-time-us_)
    attempt-time-us_ = now
    cost := 60_000_000 / attempts-per-minute
    if attempt-credit-us_ < cost or connections_ >= max-connections:
      throw "QUOTA_EXCEEDED"
    attempt-credit-us_ -= cost
    connections_++

  /** Gives back a connection taken with $open-connection. */
  close-connection -> none:
    connections_--

  /**
  Accounts for $n bytes sent or received. Throws QUOTA_EXCEEDED if that
    exceeds $bytes-per-day in the current day (the first day starts when the
    grant is created). Returns how many milliseconds the caller must wait
    before it transfers them, so that the rate stays below
    $bytes-per-second (with a burst of one second).
  */
  take-bytes n/int -> int:
    now := Time.monotonic-us
    if now - day-start-us_ >= DAY-US_:
      day-start-us_ = now
      day-bytes_ = 0
    if day-bytes_ + n > bytes-per-day: throw "QUOTA_EXCEEDED"
    day-bytes_ += n
    capacity := bytes-per-second * 1_000_000
    byte-credit_ = min capacity (byte-credit_ + (now - byte-time-us_) * bytes-per-second)
    byte-time-us_ = now
    byte-credit_ -= n * 1_000_000
    if byte-credit_ >= 0: return 0
    return (-byte-credit_ / bytes-per-second + 999) / 1000

  connections -> int:
    return connections_

/**
Whether the IPv4 $address is a public unicast address: not in 0/8, 10/8,
  100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.0.2/24,
  192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, or 224/3 (multicast,
  reserved, broadcast).
*/
is-public-address address/ByteArray -> bool:
  a := address[0]
  b := address[1]
  c := address[2]
  if a == 0 or a == 10 or a == 127 or a >= 224: return false
  if a == 100 and b & 0xc0 == 64: return false
  if a == 169 and b == 254: return false
  if a == 172 and b & 0xf0 == 16: return false
  if a == 192 and b == 0 and (c == 0 or c == 2): return false
  if a == 192 and b == 168: return false
  if a == 198 and (b & 0xfe == 18 or (b == 51 and c == 100)): return false
  if a == 203 and b == 0 and c == 113: return false
  return true

/** Parses a dotted IPv4 address; null if $host isn't one. */
parse-ipv4 host/string -> ByteArray?:
  parts := host.split "."
  if parts.size != 4: return null
  result := ByteArray 4
  for i := 0; i < 4; i++:
    part/string := parts[i]
    if part.is-empty or part.size > 3: return null
    value := 0
    part.do --runes: | c |
      if not '0' <= c <= '9': return null
      value = value * 10 + c - '0'
    if value > 255: return null
    result[i] = value
  return result

parse-rule_ rule/any -> Rule_:
  if rule is not string: throw "WRONG_OBJECT_TYPE"
  if rule.size > MAX-RULE-SIZE: throw "INVALID_ARGUMENT"
  path/string? := null
  slash := rule.index-of "/"
  if slash >= 0:
    path = rule[slash..]
    rule = rule[..slash]
    if not is-plain-path_ path: throw "INVALID_ARGUMENT"
  colon := rule.index-of ":"
  if colon <= 0: throw "INVALID_ARGUMENT"
  host := rule[..colon].to-ascii-lower
  ports := rule[colon + 1..]
  dash := ports.index-of "-"
  from := parse-port_ (dash < 0 ? ports : ports[..dash])
  to := dash < 0 ? from : parse-port_ ports[dash + 1..]
  if from > to: throw "INVALID_ARGUMENT"
  wildcard := host.starts-with "*."
  if not is-valid-host_ (wildcard ? host[2..] : host): throw "INVALID_ARGUMENT"
  ip := wildcard ? null : parse-ipv4 host
  return Rule_ host ip from to path

parse-port_ text/string -> int:
  if text.is-empty or text.size > 5: throw "INVALID_ARGUMENT"
  value := 0
  text.do --runes: | c |
    if not '0' <= c <= '9': throw "INVALID_ARGUMENT"
    value = value * 10 + c - '0'
  if not 1 <= value <= 65535: throw "INVALID_ARGUMENT"
  return value

// A host name or IPv4 address: letters, digits, '-' and '.', no empty
// labels.
is-valid-host_ host/string -> bool:
  if host.is-empty or host.size > MAX-HOST-SIZE: return false
  if host.starts-with "." or host.ends-with "." or host.contains "..": return false
  host.do --runes: | c |
    if not ('a' <= c <= 'z' or 'A' <= c <= 'Z' or '0' <= c <= '9' or c == '-' or c == '.'):
      return false
  return true

// A request path that a server can't interpret as a different path:
// printable ASCII without spaces, backslashes, dot segments or encoded
// dots and slashes.
is-plain-path_ path/string -> bool:
  if not path.starts-with "/" or path.size > 2048: return false
  path.do --runes: | c |
    if c <= ' ' or c >= 0x7f or c == '\\': return false
  lower := path.to-ascii-lower
  if lower.contains "%2e" or lower.contains "%2f" or lower.contains "%5c": return false
  segments := (path.split "?")[0].split "/"
  return not (segments.any: it == "." or it == "..")
