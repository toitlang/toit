---
name: toit-services
description: How Toit services work. Use when designing or implementing inter-container RPC APIs with `system.services` (ServiceSelector, ServiceClient, ServiceProvider).
---

# Toit Services Skill
Toit services are the high-level abstraction over RPC for communication between
containers (typically separate processes that don't share memory). One container
*provides* a service; one or more *clients* discover it and call it like a local
object. See also [the services tutorial](https://docs.toit.io/tutorials/containers/services).

## When to use this skill
Use this when:
- defining an API that crosses a container boundary,
- writing a `ServiceClient` or `ServiceProvider`,
- exposing a driver/peripheral as a system-wide service (see also `toit-driver`),
- adding methods to an existing service (versioning, indexes).

If a hardware driver just needs to expose `read` / `write` to other containers,
prefer using a published abstraction package like `sensors` (see `toit-driver`).
Define a brand-new service only when no existing package fits.

## The three pieces
A service consists of three logically separate units. They are usually placed in
three subdirectories so that clients don't drag in provider code:

```
src/apis/foo.toit       // Selector (UUID + version) and method-index constants.
src/clients/foo.toit    // Subclass of ServiceClient. User-friendly facade.
src/providers/foo.toit  // Subclass of ServiceProvider + ServiceHandler. Real impl.
```

A top-level `src/foo.toit` typically declares the public *interface* and a
small `v1` getter that opens a client. Users only import `src/foo.toit`.

### 1. API: selector + method indexes
The selector is a stable identity (UUID + major.minor) that providers and
clients use to find each other. Each method gets a small integer index.

```toit
import system.services

UUID ::= "81d183f5-6e73-403e-a3cc-9baf13b391d4"

SELECTOR-v1 ::= services.ServiceSelector
    --uuid=UUID
    --major=1
    --minor=0

READ-INDEX-v1 ::= 0
```

Generate a fresh UUID for every new service. Bump *minor* when adding methods,
*major* on incompatible changes. Once shipped, never reuse an index.

### 2. Public interface + client opener
Library users import this. Hide the `ServiceClient` subclass behind an
`interface` so users program against the API, not the transport.

```toit
import .clients.foo as clients

/**
Opens a new client for the foo service.
Requires that a FooProvider is installed.
*/
v1 -> FooService-v1: return (clients.FooService-v1).open as any

interface FooService-v1:
  read -> float?
  close -> none
```

### 3. Client
Subclass `ServiceClient`, implement the interface, forward each method through
`invoke_` with its index.

```toit
import system.services
import ..foo as client
import ..apis.foo as api

class FooService-v1 extends services.ServiceClient implements client.FooService-v1:
  static SELECTOR ::= api.SELECTOR-v1
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  read -> float?:
    return invoke_ api.READ-INDEX-v1 null
```

The base class' `open` discovers the provider, opens an RPC channel, and
installs a finalizer that closes the channel if the client is GC'd. Always
call `close` explicitly when done.

### 4. Provider
Subclass `ServiceProvider`, implement `ServiceHandler` (directly or via a
separate object), and call `provides` for each selector you serve.

```toit
import system.services
import ..apis.foo as api

class FooProvider extends services.ServiceProvider
    implements services.ServiceHandler:
  constructor:
    super "toit.io/example/foo" --major=1 --minor=0
    provides api.SELECTOR-v1 --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.READ-INDEX-v1: return 25.0
    unreachable

main:
  provider := FooProvider
  provider.install
  // Run forever, or until uninstall.
```

`handle` runs on the provider container. `arguments` is whatever the client
passed to `invoke_`; the return value is sent back. All values must be
RPC-serializable (primitives, strings, byte arrays, lists, maps,
`ServiceResource` instances — see below).

If a provider serves several unrelated APIs, give each its own
`ServiceHandler` object so method indexes can't collide.

## Versioning
- Keep old indexes stable forever.
- Bump *minor* when adding new methods (old clients keep working).
- Bump *major* on breaking changes (rename modules `*-v2`, keep `*-v1`).
- A provider may register multiple selector versions and dispatch on the
  index range or the handler.

## Lifecycle hooks
Override on the provider to react to clients connecting/disconnecting:

```toit
on-opened client/int -> none:
  // First call happens before handle is ever invoked for `client`.

on-closed client/int -> none:
  // Called when the client closes, GCs, or its container terminates.
```

The `count_` pattern from `toit-sensors`'s `Provider` (open the underlying
hardware on the first client, close on the last) is a good template when the
backing resource is expensive to keep open.

`install` / `uninstall` are the provider-side bracket. `uninstall --wait`
blocks until at least one client has connected and all clients have closed —
useful for "serve one connection then exit" containers.

## Resources and notifications (advanced)
Use `ServiceResource` / `ServiceResourceProxy` when a single client conversation
involves long-lived stateful objects (open files, subscriptions, sockets):

- The provider creates a `ServiceResource` and returns it from `handle`. The
  base class serializes it as an integer handle.
- The client's `invoke_` returns that handle; wrap it in a
  `ServiceResourceProxy` subclass and return that to the user.
- The provider can push asynchronous notifications via
  `resource.notify_ value`; the proxy receives them in `on-notified_`.
  Pass `--notifiable` when constructing the resource to enable this.
- Resources are auto-closed when the client closes or its container dies.

If the API only does request/response with simple values, you don't need
resources — return primitives directly from `handle`.

## Discovery, priority, restrictions
Multiple providers can register the same selector. The client picks one:

- `provides` accepts `--priority=` (defaults to `PRIORITY-NORMAL`). Higher wins.
- Clients can narrow discovery with `selector.restrict.allow --name=...` /
  `--tag=...` / `.deny ...`. Useful when several drivers implement the same
  abstract sensor and the user wants a specific one.
- The default `open` waits up to 100 ms for a matching provider; pass
  `--timeout=null` for non-blocking, or a longer `Duration` to wait longer.

## Running provider and client
Provider and client typically live in different containers. For testing, you
can spawn the provider in the same process:

```toit
main:
  spawn::
    provider := install
    sleep --ms=1000
    provider.uninstall
  yield  // Let the spawned process register before opening a client.
  client := foo.v1
  print client.read
  client.close
```

In production, install the provider in a long-running container (e.g. via
`jag container install`) and let user code in other containers open clients.

## SDK reference
The full implementation lives in the SDK at `lib/system/services.toit`. Use
`toit info sdk --output-format json | jq -r '."lib-path"'` to find your SDK
path (see `toit-code`).
