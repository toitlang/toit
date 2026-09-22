# Experimental host feature matrix

Current service protocol: **0.24**, as declared by
[`service/api.toit`](../../lib/ble/experimental/service/api.toit). The host remains
opt-in; the default ESP32 backend is NimBLE. This inventory separates implemented
features from production acceptance. It is not a Core 6.3 conformance claim.
The [roadmap](roadmap.md) owns acceptance criteria and
[implementation evidence](progress.md) records individual campaigns and failures.

The current API includes broadcast payload updates (0.22), writable User
Descriptions (0.23), and advertising updates during peripheral acceptance (0.24).
An installed provider advertises its operation set; selecting a smaller provider
can remove unreachable protocol code. Client tree shaking does not shrink an
already-installed provider. See [provider selection](README.md#choose-the-installed-provider)
and [API migration](api-migration.md) for ownership and compatibility.

| Feature | Current implementation | Evidence / limit |
| --- | --- | --- |
| Controller access | Linux HCI user channel; ESP32 and ESP32-S3 VHCI | Real devices; exclusive ownership, controller-only builds; PSRAM-enabled S3 lifecycle/GC and unencrypted GATT echo pass in both roles with an internal-RAM ingress queue ([board matrix](board-matrix.md)) |
| macOS / Windows transport | Not implemented | Design discusses platform constraints |
| HCI commands and ACL | Credits, bounded waits, ACL fragmentation/reassembly | `ble-hci-test`, queue tests, Linux/ESP32 echo |
| Shared ACL transmit budget | Controller-wide pool, per-account quota, eligible FIFO waiters | `ble-credit-pool-test`, simultaneous-send coverage in `ble-multilink-test` |
| Scanning / advertising | Legacy LE; scoped scan blocks; live broadcast payload updates | Hardware scanning and scan-pressure tests. Separate extended-command scanning supports complete legacy PDUs for discovery before extended initiating; extended advertising PDUs remain unsupported. Service 0.22 updates retain one advertising lifetime; see [API migration](api-migration.md) for ownership, failure and radio evidence. |
| Extended HCI connection commands | Separate extended central owner, LE 1M and explicit public/random on-air addresses | 11 direct cancellation cases; two Linux-to-S3 connections with 200 exact reads and 20 full GCs. No controller identity resolution; existing service providers retain their previous owners |
| Finite connectable advertising | Separate bounded owner uses legacy PDUs through extended HCI commands; natural expiry accounts for canceled accepts | 27 direct window/setup cases; Linux/S3 direct cancellation and S3 reverse-order radio evidence pass with survivor traffic, GC and reuse. Scripted mixed RPC cancellation passes; S3 separate-container normal closure/restart passes both orders. Mixed-role security and client-death evidence is tracked separately in [mixed-role services](mixed-role-services.md); statistical RF race gates remain. Original ESP32 is unsupported |
| Connections | Bounded live registry, default one; configured multi-link routing and link-local ATT/GATT teardown | Two-link software tests and 200 lifetime replacements; physical ESP32 central with ESP32 and S3 peers passes three echoes during another peer's delayed read, then 100 interleaved exchanges each and 20 survivor exchanges after disconnect ([board matrix](board-matrix.md)); PSRAM S3 central also passes two authenticated links with distinct protected values and survivor reads; two separate service client containers also pass authenticated peers and graceful and forced client-exit isolation; provider death and isolated OOM recovery also pass scoped radio fixtures, while broader fault and load coverage remain open |
| ATT MTU | Client and server configurable from 23 to 517, default 23 | `ble-mtu-client-test`, `ble-mtu-server-test`; independent BlueZ in both roles at 517, including crossing exchanges with the ESP32 client |
| Primary services / characteristics / descriptors | Discovery with 16-/128-bit UUIDs | `ble-hci-test`, `ble-attribute-server-test`, `ble-discovery-edges-test`, independent BlueZ; additional discovery edge cases currently have software evidence |
| Local descriptors | Explicit parent, independent read/write/security permissions; writable UTF-8 User Description with stack-owned Extended Properties metadata | `ble-local-descriptor-test`, `ble-service-local-descriptor-test`, and 11,833-case `ble-description-replay-test`; independent Bumble MTUs 23/247/517 and ESP32/S3 service radio at MTU 247. Writable Auxiliaries is advertised; Reliable Write on the characteristic value is not implied. See [API migration](api-migration.md) |
| Database and bonded server state | Sealed layout; at most 64 attributes; Service Changed in defaults unless explicitly immutable. Optional protected CCCD persistence and explicit offline database migration | `ble-cccd-session-test`, `ble-cccd-pairing-test`, `ble-cccd-migration-test`; independent ESP32/S3 reconnect/reset and moved-handle migration evidence in [cache policy](cache-policy.md) and [database migration](database-migration.md). Database Hash/robust caching is not implemented; production provisioning and interrupted-storage recovery remain open |
| Client cache invalidation | Scoped Service Changed monitor, conservative connection revision, checked discovery and short/long read/write | `ble-cache-invalidation-test`, `ble-service-central-cache-test`; unbonded BlueZ radio handle-reuse migration passes; no persistent/bonded cache; active subscription invalidation requires reconnect |
| Short reads / acknowledged writes | Client and server | Software and hardware echo |
| Long reads | Direct ATT client `read-long`; server Read Blob | `ble-long-read-test`; BlueZ and new client read exact 512-byte values at MTU 23; server also tested at 517 |
| Value sizes | Database/service defaults to 20; explicit `--value-limit` up to 512 | Bounds and offsets tested; independent service RPC radio transfers at 512 bytes; MTU remains separately negotiated |
| Dynamic reads / validation | Scoped blocks, deadlines, owned replies | Dynamic-handler and service tests; each blob read invokes the handler anew |
| Prepared writes / long writes | Client checked echoes and serialized Prepare/Execute/Cancel; server atomic commit | `ble-long-write-test`, BlueZ and new Toit client against ESP32, ESP32 client against BlueZ server; 512-byte maximum, 8–29 queued PDUs according to database value limit |
| Notifications | Both directions; up to eight scoped client subscriptions | Shared bounded client queues and explicit overflow; direct server may truncate by option, while service notifications reject oversized values |
| Indications / confirmations | Client receives/confirms; server submits one pending indication with a receipt and deadline; scoped CCCD indication enable | Client/server software tests; independent BlueZ in both roles: 100 exact 512-byte indications/confirmations with GC in each direction |
| Write Without Response | Central raw/view/typed commands; separate local command permission and accepted-message callbacks | Software ownership/cancellation/revision coverage; independent BlueZ command-only radio in both roles, including empty values; no peer acknowledgement or automatic retry |
| Connection parameters | Peripheral L2CAP request; central HCI update; opt-in peer request acceptance with bounded workers | `ble-connection-update-test`, `ble-peer-parameters-test`; ESP32 central applied 15/50 ms intervals against BlueZ with 100 indications and GC; ESP32 peripheral requests accepted by PSRAM S3 central at both intervals, with 40 exact reads and observed GC on both boards ([board matrix](board-matrix.md)) |
| SC derivation functions | f4, f5, f6, g2 using SDK AES-CMAC | `ble-sc-crypto-test`, Core Appendix D vectors; [security status](security.md) |
| SC P-256 agreement | SDK key generation/ECDH, managed native result, SMP coordinate conversion, debug-key rejection | `ble-sc-ecdh-test`, Core P-256 data set2 and invalid-point tests; current ESP32/S3 native error-classification and retention regressions each pass45 full/compacting GCs; [security scope](security.md) |
| SMP feature selection | Owned feature parsing, SC/full-key policy, explicit association selection | `ble-smp-features-test`; all 25 IO combinations; Just Works and Numeric Comparison protocol/radio evidence; other association modes remain outside current implementation |
| Secret check comparison | Fixed-width SC helper backed by native mbedTLS comparison | `crypto-compare-test`, `ble-sc-crypto-test`; lengths are public; rebuilt native firmware required |
| SMP protocol engine | SC Just Works/Numeric Comparison, explicit approval, candidate-key gating and identity distribution | Software transcripts and independent BlueZ pairing in both roles; ESP32/S3 Numeric Comparison and protected reads pass in both roles ([board matrix](board-matrix.md)); fixture approval is not a production user interface |
| Encryption controller boundary | SC central encryption, peripheral key replies, per-link encryption state | Software tests and independent encrypted transfers in both roles; see security and progress records for exact configurations |
| Pairing / encryption / bonds / privacy | SC pairing/encryption, authenticated candidate storage, public/random identity and RPA support | Public-address peripheral resume passed against BlueZ; central resume and explicit replacement passed against NimBLE after both boards restarted; independent Bumble and table-backed service providers pass authenticated pair/app-flash/resume plus controlled overflow recovery on ESP32/S3. Immediate central resumption against BlueZ still fails; the [Linux diagnosis](linux-resumption-diagnosis.md) identifies a request-callback mismatch candidate requiring running-kernel validation. The diagnostic ordering control does not close that gate. Private BlueZ reconnect and production key lifecycle/policy remain open |
| Host privacy | RPA generation/resolution, pairing identity distribution, provider-selected connection addresses; opt-in timed scanning and non-connectable advertising rotation | [Scanning privacy](scanning-privacy.md), [advertising privacy](advertising-privacy.md) and [security](security.md) distinguish arithmetic, software, independent radio and lifecycle evidence. Controller identity resolution and universal concurrent-role rotation are not implemented |
| Service API | Protocol 0.24: explicit mixed provider admits two central clients or one per role; ordinary providers retain their policy. Advertising/scan stay exclusive. Typed records, local builder/descriptors and scoped blocks | Scripted mixed admission/cancellation,17 real-SMP security cases and8 early-resumption/revocation cases pass. Key replies progress during pending setup. S3 containers pass both orders, restart/client death with survivors and GC. Public-peer authenticated resumption passes before/after both boards reboot:1400 protected reads per phase and unchanged bonds, fresh pairing forbidden after reboot. A preceding initial-link failure remains undiagnosed. Broader privacy/independent hosts, storage faults, pending initiation/provider death, load and production limits remain open |
| GC / queue ownership | Managed small packets; bounded native ESP32 ingress | Real GC/retry/pressure tests; production memory budget pending |

## Operating and ownership limits

The default connection limit is one. Shared central providers can admit two
clients; the explicit mixed provider supports two central sessions or one per
role on supporting controllers. Standalone scanning and advertising remain
exclusive. Admission reserves pending setup and teardown as well as live links.
See [mixed-role services](mixed-role-services.md) for controller requirements and
measured combinations; two-link software coverage does not establish arbitrary
multi-role interoperability or production load limits.

The L2CAP receive limit defaults to 65 and can be configured up to 1024. It must
cover the database's advertised ATT MTU; server construction rejects an
incompatible limit. Value size and MTU are separate settings. Prepared writes
have both an entry limit and a separate aggregate byte budget (144–522 bytes as
the value limit grows). Long reads do not promise a snapshot across requests;
applications needing that consistency must provide it.

Application byte arrays are copied before RPC so external buffers are not
neutered. Returned values are owned, but RPC can make payloads above 128 bytes
external; ownership does not imply compactability. The native ESP32 ingress
queue has eight fixed slots with two reserved against advertising-report load.
Allocation happens before dequeue, and controller sends retain no managed
pointer beyond the synchronous primitive. See [native checks](native-checks.md)
and [RPC measurements](rpc-measurements.md) for evidence and copy costs.

Security is explicit through `--encrypted` / `--authenticated` attribute
permissions and trusted provider pairing/bond policy. Observed security snapshots
do not replace live access checks. Default providers do not provision durable
bonds or CCCD storage: trusted overrides bind persistence to the selected bond
and database revision. Bond administration is a separate service with no default
grant. See [security](security.md) and [cache policy](cache-policy.md).

Service notifications reject values exceeding MTU minus three; the direct API
retains its documented truncation option. Subscriptions have bounded queues and
explicit overflow. Peer receipt of an indication is acknowledged by the provider
before application processing, so it is not an application-delivery guarantee.
There is no automatic replay of uncertain writes or notifications.

## Open production gates

The recorded 24-hour run and successful connection-cycle campaigns are scoped
evidence. Preserved reconnect failures, immediate BlueZ central resumption,
broader role/security interoperability, production key provisioning and storage
recovery, platform regression builds and release qualification still need their
own acceptance evidence. No default-backend switch follows from individual
passing tests. The [roadmap's release criteria](roadmap.md#10-establish-production-release-evidence)
and linked campaign records retain the exact requirements and unresolved limits.

Incremental version notes and their original, sometimes superseded limitations
are preserved in [feature history](feature-history.md). Historical statements
that a soak was running or a feature was pending are not current rig state;
use the [board matrix](board-matrix.md) for the latest terminal records.
