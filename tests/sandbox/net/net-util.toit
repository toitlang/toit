// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Support for the tests of the sandbox network services.

Every test is a program that runs as the driver (the trusted application
  container started by toit.run) and as the sandboxes the driver starts
  from the same image. The driver runs local servers (TCP echo, HTTP, TLS)
  on the loopback interface; the sandboxes reach them through the sandbox
  network provider (a trusted container from the same image, started with
  the policy each case needs), so its policy must list the loopback
  address explicitly (or be "all").
*/

import expect show *
import http
import io
import log
import monitor
import net
import net.tcp
import tls
import system.containers
import system.api.sandbox-network show SandboxSocketService SandboxHttpService SandboxNetworkClient open-session
import ....services.sandbox-network.provider show run-sandbox-network

SOCKET-SERVICE ::= SandboxSocketService.SELECTOR.uuid
HTTP-SERVICE ::= SandboxHttpService.SELECTOR.uuid

/**
Runs the test: in the driver, calls $driver and stops the sandbox network
  provider if it started one; in a sandbox, calls the block of $roles for
  its role with the arguments map; in the provider container, runs the
  provider. A sandbox that throws exits with 1 (uncaught exception).
*/
run-test args/any --roles/Map [driver] -> none:
  if args is Map:
    role := args["role"]
    if role == PROVIDER-ROLE:
      run-sandbox-network --network=args["network"]
      return
    (roles[role]).call args
    return
  driver.call
  stop-provider
  print "OK"

PROVIDER-ROLE ::= "network-provider"

/** The value of a $start-sandbox argument that wasn't given. */
UNSET ::= Object
/** A $start-sandbox network for a provider without a policy (null means
  the default in Toit). */
NO-POLICY ::= "no-policy"

provider_/containers.Container? := null
provider-policy_/string? := null

/**
Starts the sandbox network provider with the given $network policy as a
  trusted container from this image (with a heap quota) and waits until it
  serves.
*/
start-provider --network/any --heap/int=4_000_000 -> containers.Container:
  if network == NO-POLICY: network = null
  container := containers.start containers.current {"role": PROVIDER-ROLE, "network": network}
      --quotas={"heap": heap}
  wait-for-provider
  return container

/** Runs the provider with the $network policy, restarting it for another one. */
use-provider network/any -> none:
  key := "$network"
  if provider_ and provider-policy_ == key: return
  stop-provider
  provider_ = start-provider --network=network
  provider-policy_ = key

stop-provider -> none:
  if not provider_: return
  provider_.stop
  provider_ = null
  provider-policy_ = null

wait-for-provider -> none:
  [SandboxSocketService.SELECTOR, SandboxHttpService.SELECTOR].do: | selector |
    (open-session selector (Duration --s=5) "provider not up").close

/**
Starts a sandbox from this image with the given $role and $arguments and
  waits for it. Returns its exit code.

If $network is given, the provider runs with that policy (null: none);
  the sandbox may use the network services unless $services says
  otherwise.
*/
run-sandbox role/string arguments/Map={:} --services/any=UNSET --network/any=UNSET --quotas/Map?=null -> int:
  return (start-sandbox role arguments --services=services --network=network --quotas=quotas).wait

start-sandbox role/string arguments/Map={:} --services/any=UNSET --network/any=UNSET --quotas/Map?=null -> containers.Container:
  if network != UNSET: use-provider network
  all := {"role": role}
  arguments.do: | key value | all[key] = value
  return containers.start containers.current all
      --untrusted
      --services=(services == UNSET ? [SOCKET-SERVICE, HTTP-SERVICE] : services)
      --quotas=quotas

expect-sandbox role/string arguments/Map={:} --services/any=UNSET --network/any=UNSET --quotas/Map?=null -> none:
  code := run-sandbox role arguments --services=services --network=network --quotas=quotas
  print "sandbox $role: exit $code"
  if code != 0: throw "sandbox $role exited with $code"

/** The bytes of a test pattern: byte i is i * 7 + i / 256 (mod 256). */
pattern size/int -> ByteArray:
  return ByteArray size: (it * 7 + it / 256) & 0xff

/** A TCP echo server on the loopback interface. */
class EchoServer:
  network_/net.Client
  socket_/tcp.ServerSocket
  port/int
  open/int := 0     // Connections currently open.
  accepted/int := 0
  changed ::= monitor.Signal
  task_/Task? := null

  constructor:
    network_ = net.open
    socket_ = network_.tcp-listen 0
    port = socket_.local-address.port
    task_ = task::
      while true:
        connection := socket_.accept
        // Null: no connection after all (the state was cleared).
        if not connection: continue
        accepted++
        open++
        changed.raise
        task::
          catch:
            while data := connection.in.read:
              connection.out.write data
            connection.out.close
          connection.close
          open--
          changed.raise

  /** Waits until $open connections are open (at most 20 s: the machine may be loaded). */
  wait-open count/int -> none:
    with-timeout --ms=20_000:
      changed.wait: open == count

  close -> none:
    task_.cancel
    socket_.close
    network_.close

/**
An HTTP (or, with a certificate, HTTPS) server on the loopback interface.

Paths:
- /small: "hello".
- /echo: the request body.
- /count: the size of the request body.
- /big?n=N: N bytes of $pattern, with a content length.
- /chunked?n=N: N bytes of $pattern, chunked.
- /redirect: a redirect to /small.
- /slow: "slow" after 3 seconds.
- /headers: the request's X-Test header.
- anything else: the path.
*/
class HttpServer:
  network_/net.Client
  socket_/tcp.ServerSocket
  port/int
  requests/int := 0
  task_/Task? := null
  patterns_ ::= {:}  // The server's cost stays out of the measurements.

  constructor --certificate/tls.Certificate?=null:
    network_ = net.open
    socket_ = network_.tcp-listen 0
    port = socket_.local-address.port
    server := certificate
        ? http.Server.tls --certificate=certificate --max-tasks=8 --logger=(log-nothing_)
        : http.Server --max-tasks=8 --logger=(log-nothing_)
    task_ = task::
      server.listen socket_:: | request/http.RequestIncoming writer/http.ResponseWriter |
        requests++
        handle_ request writer

  static log-nothing_:
    return (log.Logger log.FATAL-LEVEL log.DefaultTarget)

  handle_ request/http.RequestIncoming writer/http.ResponseWriter -> none:
    path := request.path
    query := request.query
    n := int.parse (query.parameters.get "n" --if-absent=: "0")
    if path.starts-with "/small":
      writer.headers.set "Content-Length" "5"
      writer.out.write "hello"
    else if path.starts-with "/echo":
      writer.out.write request.body.read-all
    else if path.starts-with "/count":
      size := 0
      while chunk := request.body.read: size += chunk.size
      writer.out.write "$size"
    else if path.starts-with "/big":
      writer.headers.set "Content-Length" "$n"
      data := patterns_.get n --init=: pattern n
      List.chunk-up 0 n 4096: | from to _ | writer.out.write data[from..to]
    else if path.starts-with "/chunked":
      data := patterns_.get n --init=: pattern n
      List.chunk-up 0 n 1000: | from to _ | writer.out.write data[from..to]
    else if path.starts-with "/redirect":
      writer.redirect http.STATUS-FOUND "/small"
      return
    else if path.starts-with "/slow":
      sleep --ms=3_000
      writer.out.write "slow"
    else if path.starts-with "/headers":
      writer.out.write (request.headers.single "X-Test" or "none")
    else:
      writer.out.write path

  close -> none:
    task_.cancel
    socket_.close
    network_.close
