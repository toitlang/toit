# Limits on service calls of sandboxed clients

Design note. Nothing here is implemented yet; see docs/sandbox-policy.md
for what is.

A sandboxed (untrusted) container reaches the rest of the system only
through messages: to the system process (discovery, print, traces) and to
the service providers it discovered. Printing and tracing are service
calls like any other, so their limits should come from one general
mechanism for service calls instead of special cases in the print service
and the trace handler. This note describes what bounds such calls today,
what a general per-client budget would look like, where it could be
enforced, and how print, trace and log fall out of it.

## What exists today

Memory and queue bounds, enforced by the VM (`src/primitive_policy.h`,
`Process::_append_message`, `process_send`):

| Bound | Default (host / device) | Scope |
|---|---|---|
| message size (`max_message_bytes`, including external byte arrays) | 256 KB / 8 KB | per message |
| message types | RPC request, reply, cancel, resource notification, trace (to the system process only), user types >= 64 | per message |
| allowed targets (`max_send_grants`) | 64 pids | per group; granted by discovery and by incoming RPC requests |
| messages a sender may have queued in one mailbox (`max_mailbox_messages`) | 256 | per receiver, summed over all sandboxed senders |
| bytes a sender may have queued in one mailbox (`max_mailbox_bytes`) | 1 MB / 32 KB | per receiver, summed over all sandboxed senders |
| total mailbox of a sandboxed receiver | 4 x the two above | per receiver |
| run time, CPU budget | 2 s / unlimited | per process |

A sandboxed sender that hits a mailbox quota gets `QUOTA_EXCEEDED`; a
trusted sender's message to a full sandboxed mailbox is dropped.

Limits in the Toit libraries, added by the sandbox audit
(docs/sandbox-policy.md, "Quotas"):

| Limit | Value | Where |
|---|---|---|
| unprocessed RPC requests of one sandboxed process | 8 per provider process | `RpcBroker` (`lib/rpc/broker.toit`) |
| open clients of one sandboxed process | 32 per provider process | `ServiceManager_.open` (`lib/system/services.toit`) |
| registered services, pending discoveries, string sizes | 16, 16, 128 bytes, 8 tags | `SystemServiceManager` (`system/services.toit`) |
| print message size | 4 KB, then truncated | `SandboxPrintServiceProvider` |

What none of them bounds is the *rate*: a sandbox that waits for each
reply stays under every count above and can still call a provider as fast
as the provider answers. For most services that only costs the provider's
CPU time (which the scheduler shares fairly). For output it doesn't: every
print and every trace ends on the console, and every message of a type
without handler makes the receiver print a warning. On a device with a
UART console (115200 baud, about 11 KB/s) a sandbox printing 4 KB lines,
or sending 8 KB traces that are printed base64-encoded, keeps the system
process busy writing, and the output of every other container drowns.

## A per-client budget for service calls

Every provider keeps, for each sandboxed client group (the container, not
the pid: the VM gives every message the sender's group id, which can't be
forged, and a group may have several processes), a token bucket with two
dimensions:

- requests: refilled at `r` requests per second up to a burst of `R`;
- bytes: refilled at `b` bytes per second up to a burst of `B`, charged
  with the encoded size of the request (the VM knows it when it copies
  the message; the broker would get it with the message) and, after the
  fact, with the size of the reply or of notifications sent to the client.

A request is charged when it is taken from the mailbox, before it is
decoded further or dispatched. If the bucket is empty the request is
refused with a distinct error (`RATE_LIMITED`) instead of being queued, so
a client can tell it from a failure and back off, and refused requests
don't pile up anywhere. Reply bytes are charged as debt: they can take
the bucket below zero, which refuses the following requests until it
refills.

The values come from three places, the most specific winning:

1. defaults for sandboxed clients (generous: the point is to bound
   floods, not to throttle normal programs);
2. the client's launch policy: new quota keys next to the existing ones,
   for example `"service-requests-per-s"` and `"service-bytes-per-s"`,
   applied per provider;
3. the provider, per service: a provider that knows its calls are
   expensive (or, like print, produce output) declares a tighter budget,
   and can charge more than one token for an expensive method.

Trusted clients are not limited; they are trusted not to flood.

### Where to enforce it

**In the system process' broker (discovery).** The system process only
sees the calls to its own services (discovery, print, containers,
storage, ...). Calls to other providers go from the client to the
provider directly; the system process only hands out the capability. So
it can enforce budgets for system services, but it is not a general
mechanism.

**In lib/system/services.toit, on the provider side.** Every provider
that uses the service library (`ServiceManager_` and its `RpcBroker`) sees
every request with the sender's pid and group, the service and the method
index, before it dispatches it. This is where the existing per-client
limits already live (unprocessed requests, open clients), it is the same
code for the system process and for every other provider, and it can
weigh methods. The budget values of the client's launch policy are known
to the system process (it starts containers and keeps their policies);
other providers would need to learn them, through a small extension of
`process_policy` (which today returns the policy kind only) or by asking
the system process. A provider that doesn't use the library isn't
protected, but that is its own choice. Sandboxed providers serve only
trusted clients, which aren't limited, so they don't need the budget
(and couldn't query policies anyway).

The cost of this placement: the request has already been copied into the
provider's mailbox and decoded when it is refused. The VM's mailbox
quotas bound that memory, so it is a CPU cost proportional to the
refused requests, and the provider spends it at its own pace.

**In the VM's send gate.** The VM sees every message with sender,
receiver and size, and could refuse a message before it allocates
anything. But it knows nothing about services and methods, it would need
time-based state per (sender group, receiver) pair in the VM, and policy
about rates would move into the trusted base of every process' sends,
not only of service calls. It also can't charge replies to the client
that caused them.

**Recommendation.** Keep the VM's bounds as they are (they bound memory,
whatever the receiver does) and put the budget in lib/system/services.toit,
next to the existing per-client limits: one implementation, used by the
system process for its own services from the start, and by every other
provider that serves sandboxes. The system process' budgets for its own
services come straight from the container's policy; other providers start
with the defaults and their own declarations, and learn the policy's
values once `process_policy` can report them.

## Print, trace and log

**Print.** `print` in a sandbox is a call of the system process' sandbox
print service. With the budget, the print service declares a bytes budget
that matches the console (for example a burst of 4 KB and 1 KB/s per
sandbox on devices, more on hosts) and, instead of refusing the call
(which would turn a log line into an exception in the program), drops the
line and counts it; when the bucket refills it prints one line
`[N lines from container G dropped]`. The 4 KB truncation of a single
message stays.

**Log.** The log library sends to a `LogService` provider if one serves
sandboxed clients, and falls back to print otherwise. Either way the
call is a service call: the log provider's budget, or the print
service's.

**Trace.** A trace (`SYSTEM_TRACE`, sent for uncaught exceptions) is a
system message to the system process, not an RPC, and the system process
prints it (decoded with the program's source map on hosts, base64 on
devices). It falls into the same accounting by charging the trace to the
sender group's bucket of a pseudo-service `system/trace` in the system
process, with the same budget code: within budget the trace is printed as
today; beyond it, only a one-line summary (container, exception name,
size). The first trace of each process is always printed in full: it is
usually the reason the process died.

**Unhandled message types.** A message of a type without handler makes
the receiver print a warning, once per message. The same bucket applies:
the warning is printed within budget and summarized beyond it (`N
unhandled messages of type T from container G`).

## Interaction with the open questions

Two related questions stay open by owner decision (docs/sandbox-policy.md,
"Open questions").

**Mailbox quotas are per receiver.** A sandbox can fill the mailbox of the
system process and of each of its up to 64 granted providers up to the
per-sender quota, and the quota of a receiver is shared by all sandboxed
senders, so one sandbox can lock others out of a slow receiver. A
per-client service budget doesn't change either: the messages are in the
mailbox before the provider's library sees them, so the budget bounds
what a provider does for a client, not what the VM holds for a slow
receiver. Bounding memory across receivers needs accounting in the VM per
sender group (bytes queued anywhere, released on dequeue), to be
investigated. Both use the sender's group as the key, so the budget's
bookkeeping in the libraries and a per-group mailbox budget in the VM
don't conflict, and a refused service request (`RATE_LIMITED`) is
dequeued at once, so the budget keeps a well-behaved provider's mailbox
short.

**Discovery's `watch` reveals pid liveness.** A sandbox can ask the
discovery service to watch any pid and learn whether it exists and when
it dies. `watch` is a call of the discovery service, so the budget
applies to it: scanning the pid space becomes slow (at `r` requests per
second), but the information is still there for the pids it asks about.
Closing the leak needs the system process to check the watcher's grants,
which needs a new primitive; it is accepted for now and on the list.
