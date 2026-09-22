# Service deployment size experiments

## Ownership fixes, 2026-09-22

`build/ble-size-service-024-current-002` repeats all12 provider/client fixtures
and11 offline deployments from campaign001 with the same compiler and frozen
native/system bases. All padded container, application and full-flash sizes
remain unchanged. The four ordinary, bonded and mixed GATT provider snapshots
each grow38bytes; their image contents change despite unchanged padded sizes.
The advertising/private-advertising/scan provider snapshots and images remain
byte-identical. Every client image is also byte-identical, although three client
debug snapshots differ without changing size or retained method tables.

Retained-method checks still exclude ATT/GATT/SMP from advertising and scan-only
providers. Clients retain only the service API/client modules; changing the client
still reuses the identical installed provider member. The scan provider saves
59,136 padded provider bytes and65,536 application bytes versus mixed-role GATT
with the same scan client. Source/artifact hashes, immutable envelope members,
provider reuse and partition fit verify. These are offline code-size results,
not new board or runtime-memory measurements. The separate
[allocation comparison](rpc-measurements.md#request-ownership-allocation-cost-2026-09-22)
measures the new request snapshot's host cost.

## Current service 0.24 and mixed-provider comparison, 2026-09-19

`build/ble-size-service-024-current-001` rebuilds the historical fixtures with
the current managed code and unchanged compiler. It adds minimal GATT and mixed
providers that differ only in their imported provider superclass, then assembles
four S3 configurations offline. No hardware deployment or default-provider change
is implied by these measurements.

| Provider fixture | Padded image bytes | Snapshot bytes |
| --- | ---: | ---: |
| Ordinary advertising | 59,136 | 124,192 |
| Timed private advertising | 59,136 | 127,616 |
| Scan/advertising | 63,360 | 133,680 |
| Existing ordinary GATT fixture | 118,272 | 229,788 |
| Bond-enabled GATT fixture | 152,064 | 291,684 |
| Minimal ordinary GATT | 118,272 | 228,782 |
| Minimal mixed-role GATT | 122,496 | 237,106 |

All nine historical padded provider/client images and all seven historical
application/full-flash footprints are unchanged. Ordinary GATT and bond snapshots
grow by 124 and 122 bytes; scan/GATT client snapshots each grow by 14 bytes.
These aggregate differences include changes since the earlier measurement;
they do not isolate the failure hook's cost. Method tables confirm that small
providers discard connection code and its failure hook, ordinary GATT retains
only the base hook, and the mixed provider retains the bounded-owner override.
Pairing code remains absent from both minimal providers.

| S3 configuration | Provider image bytes | Client image bytes | Application image bytes |
| --- | ---: | ---: | ---: |
| Scan provider + scan client | 63,360 | 46,464 | 1,496,368 |
| Minimal GATT + scan client | 118,272 | 46,464 | 1,561,904 |
| Minimal mixed + scan client | 122,496 | 46,464 | 1,561,904 |
| Same mixed provider + public echo client | 122,496 | 54,912 | 1,561,904 |

The mixed provider costs 4,224 padded image bytes and 8,324 snapshot bytes more
than the otherwise equivalent ordinary GATT fixture. Application-image padding
absorbs this difference. Selecting scan-only instead saves 59,136 provider bytes
and 65,536 application-image bytes versus mixed. Reserved partitions are
unchanged; every full-flash image remains 4,194,304 bytes.

Both mixed configurations contain byte-identical provider images, ID
`2324bd64-b81b-2aa3-e9f8-f1762507685a`. The historical bond-provider configurations
also reuse an identical provider member. Scan, bonded-value and public echo
clients retain only service/api and service/client among experimental BLE
modules; their retained API methods differ. An application therefore still
cannot shrink an already-built provider.

Source/artifact hashes, retained methods, native/system/table identity, image
contents and partition fit verify. The S3 mixed comparison uses the public echo
client because the minimal provider has no pairing policy; an initial size-only
combination with the bonded-value client is archived separately and is not a
usable security deployment. These are code/deployment sizes, not runtime RAM,
throughput, radio qualification or justification for another supported variant.

## Service 0.24: connectable update deployment measurements, 2026-09-13

`build/ble-size-service-024` repeats the same nine fixtures and seven offline
deployments. Native/system members and all source/artifact manifests verify.

| Provider fixture | Padded image bytes | Snapshot bytes |
| --- | ---: | ---: |
| Ordinary advertising | 59,136 | 124,192 |
| Timed private advertising | 59,136 | 127,616 |
| Scan/advertising | 63,360 | 133,680 |
| Ordinary GATT | 118,272 | 229,664 |
| Bond-enabled GATT fixture | 152,064 | 291,562 |

Advertising and scanning footprints remain unchanged. Ordinary GATT and the
bond fixture each grow by 4,224 padded bytes from the 0.23 measurement. Method
tables retain the accept-update queue only in the GATT providers; the smaller
providers omit it. Client BLE modules remain limited to service/api and
service/client. Different clients still use the identical bond-provider image,
ID `43dd5a9f-bcb3-ccc6-f4ff-9b23a9c642e0`.

All seven application-partition and complete-flash sizes remain unchanged from
the 0.23/0.22 configuration tables. With the same scan client, the scan provider
saves 54,912 padded provider bytes and 65,536 application-partition bytes versus
GATT. These are measured code/deployment footprints, not runtime RAM or a claim
that an application can shrink its installed service.

The separate passing ESP32/S3 radio fixtures have identical provider/application
snapshots of 230,688/101,234 bytes. Those fixtures include counters, peer checks
and GC assertions and do not measure an isolated API cost.

## Service 0.23: provider and deployment measurements, 2026-09-13

`build/ble-size-service-023` repeats the nine fixtures and seven configurations
below with current managed sources and the same native base and system container.
All artifacts are assembled and measured offline. Retained method tables,
immutable envelope members, source hashes and artifact hashes are verified.

| Provider fixture | Padded image bytes | Snapshot bytes |
| --- | ---: | ---: |
| Ordinary advertising | 59,136 | 124,192 |
| Timed private advertising | 59,136 | 127,616 |
| Scan/advertising | 63,360 | 133,680 |
| Ordinary GATT | 114,048 | 226,398 |
| Bond-enabled GATT fixture | 147,840 | 288,306 |

The first four padded provider sizes are unchanged from the 0.22 measurement.
The bond fixture grows by 4,224 padded bytes. These measurements include all
intervening managed changes; they do not isolate writable-description cost.
Every application partition and complete-flash size in the 0.22 configuration
table below remains unchanged. Padding explains why code growth need not change
the application partition footprint; complete images still occupy 4 MiB.

Ordinary advertising and scan/advertising omit ATT, GATT, pairing and privacy
implementations. The private advertising variant retains privacy. Ordinary
GATT retains ATT/GATT and omits the pairing implementation; the explicit bond
provider retains it. Scan and GATT application BLE modules remain limited to
`service/api` and `service/client`, with scanning versus serving methods retained
according to use. Both applications use the identical bond-provider image,
ID `612a53eb-cd1b-282b-b01d-c46a4d7ddd58`.

For the same scan client, selecting the scan/advertising provider still saves
50,688 padded container bytes and 65,536 application-partition bytes versus
ordinary GATT. Changing a client does not shrink its installed provider. These
are code/deployment measurements, not runtime RAM or radio qualification.

The separate writable-description radio fixture uses provider/application
snapshots of 226,746/100,138 bytes and passes on original ESP32. Its additional
peer/GC/value assertions make it unsuitable as an isolated feature-cost measure.

## Android CCCD fixture, 2026-09-13

The Android-specific provider and unchanged service application compile to
291,360/101,614-byte snapshots, identical on S3 and original ESP32. The provider
owns peer identity distribution, authenticated pairing and retained storage;
the Android peer adds no API surface to the Toit application. S3 passes the
four-connection/reset campaign. Original ESP32 fails Android connection setup
before pairing, so identical snapshots do not imply identical radio results.
These figures measure snapshots, not container images or runtime RAM.

## Private-address CCCD fixture, 2026-09-13

`build/ble-cccd-private-s3-002` and `build/ble-cccd-private-esp32-002` use identical
provider/application snapshots of293,540/101,614 bytes. The application is the
unchanged service-only CCCD fixture; identity distribution, address resolution
and persistent configuration selection remain in the provider. Both targets
pass private-address resumption, container replacement and board reset without
subscription rewrites. These snapshot sizes do not measure RAM, and the fixture
comparison does not isolate the cost of privacy from its additional assertions.

## Migration fixture, 2026-09-12

`build/ble-cccd-migration-radio-s3-001` and `build/ble-cccd-migration-radio-esp32-001`
run identical provider/application snapshots of267,638/101,268 bytes. Both pass
a real layout update, reset before Service Changed confirmation and later
provider/application replacement. The application's retained BLE modules remain
only service/api and service/client. The migration mapping, old/new layouts and
protected records belong to the provider, using scoped transformation blocks.

This fixture supports resumption only, whereas the earlier persistence fixture
also includes fresh pairing. Their provider-size difference is not an isolated
migration cost or a like-for-like optimization. Snapshot sizes do not measure
runtime RAM or converted container size. See [migration](database-migration.md).

## Persistent CCCD service fixture, 2026-09-12

The independent radio deployments in `build/ble-cccd-service-s3-001` and
`build/ble-cccd-service-esp32-001` run byte-identical provider and application
snapshots on S3 and original ESP32. The provider snapshot is 288,746 bytes;
the application snapshot is 101,614 bytes. Retained method tables in the S3
artifact directory show that the application's BLE modules are only
`service/api.toit` and `service/client.toit`. Protocol and protected-storage code
remain in the separately deployed provider. Provider replacement and board-reset
resumption pass with this separation; see [cache policy](cache-policy.md).

These snapshot sizes do not measure converted container size or runtime RAM.
The fixture deliberately chooses a fixed database and a full pairing/persistence
provider; it does not demonstrate an application shrinking an installed provider.

## Service 0.22: current provider and deployment measurements

Measured2026-09-11 in `build/ble-size-service-022`. The archived shell script
compiles nine fixtures using the same current host compiler, converts each to
a32-bit container image and records retained method tables. Seven configurations
use the same original-ESP32 native envelope and normal system snapshot
`c1680d2e-660a-b199-8af6-3b81dc2e6cb4`. These artifacts were assembled, not run or
flashed. Source, compiler, image and envelope hashes are retained.

| Provider fixture | Padded image bytes | Snapshot bytes |
| --- | ---: | ---: |
| Ordinary advertising | 59,136 | 123,824 |
| Timed private advertising | 59,136 | 127,248 |
| Scan/advertising | 63,360 | 133,312 |
| Ordinary GATT | 114,048 | 222,268 |
| Bond-enabled GATT fixture | 143,616 | 281,956 |

Method tables show that ordinary advertising and scan/advertising omit ACL
reassembly, ATT, GATT, SMP, privacy and AES implementations. They retain HCI,
receive-credit/error paths and the live advertising-update worker. The private
advertising fixture additionally retains privacy/AES. Ordinary GATT retains
ATT/client/server implementations and security hooks, but omits SMP pairing and
SC crypto; the explicit bond fixture retains them. No new provider variant was
introduced by this measurement.

| Configuration | Provider | Client | Application partition | Complete flash |
| --- | ---: | ---: | ---: | ---: |
| Advertising + advertising example | 59,136 | 54,912 | 1,522,144 | 4,194,304 |
| Same advertising + update fixture | 59,136 | 42,240 | 1,522,144 | 4,194,304 |
| Private advertising + advertising example | 59,136 | 54,912 | 1,522,144 | 4,194,304 |
| Scan/advertising + scan example | 63,360 | 46,464 | 1,522,144 | 4,194,304 |
| Ordinary GATT + same scan example | 114,048 | 46,464 | 1,587,680 | 4,194,304 |
| Bond-enabled GATT + same scan example | 143,616 | 46,464 | 1,653,216 | 4,194,304 |
| Same bond-enabled GATT + GATT example | 143,616 | 46,464 | 1,653,216 | 4,194,304 |

All values are bytes. The scan/advertising provider saves50,688 padded container
bytes and65,536 application-partition bytes versus ordinary GATT for the same
scan client. The bond-provider image is reused byte-for-byte with both clients;
both envelopes report provider ID `1ba74855-e0b7-519d-52e3-037be4018d4f`. Client
method tables differ: the scan example retains scanning and omits serving,
whereas the GATT example retains serving and omits scanning. Equal padded client
sizes do not imply equal code, and neither changes the provider.

Public and private advertising now share a padded image size despite different
snapshots, hashes and retained implementations. The fixed flash layout likewise
keeps all complete images at4MiB despite different application footprints. The
update fixture is smaller than the general advertising example because the
programs perform different work; this is not an isolated update-method cost.
Earlier numbers below describe their frozen sources, not current footprints.
No runtime RAM, throughput, firmware qualification or isolated before/after
optimization claim follows from these sizes.

## Explicit pairing provider

`build/ble-pairing-provider-isolation-001` separates fresh pairing from the
ordinary GATT provider. These are 32-bit container images compiled with the
same compiler as the immediately preceding retry-policy measurements.

| Provider fixture | Padded image bytes | Snapshot bytes | SMP pairing / retry history |
| --- | ---: | ---: | --- |
| Ordinary advertising | 54,912 | 120,070 | Absent |
| Ordinary scanning | 59,136 | 128,772 | Absent |
| Ordinary GATT | 109,824 | 214,932 | Absent |
| Fresh-pairing GATT | 122,496 | 245,500 | Present |
| Central pairing | 114,048 | 228,242 | Present |

Ordinary GATT falls from 122,496 to 109,824 bytes, saving 12,672 padded bytes.
Method tables also exclude its security.Pairing implementation. Advertising,
scanning and central-pairing images are byte-for-byte unchanged. Fresh-pairing
GATT retains the same padded size with a changed hash. These are container-size
and reachability results, not runtime heap or complete-flash measurements.

Fresh peripheral pairing selects `service.pairing-provider.Provider`; its IO
capability still defaults to null. The existing private GATT variant derives
from that class to preserve configured pairing. Ordinary GATT retains custom
security/resumption hooks and an explicit migration error for legacy IO-hook
users. Application RPCs are unchanged. The migration guard and all 125 BLE
CTests pass; the initial guard fixture's missing advertising-disable reply is
recorded separately from the corrected check.

The explicit provider also passes a two-board authenticated descriptor test in
`build/ble-pairing-provider-radio-001`: separate provider/application containers,
security denial before pairing, matching fresh Numeric Comparison, exact long
and empty transfers, retained write buffers across GC and normal completion.
This validates the pairing deployment on ESP32/S3; it adds no runtime heap claim.

## Pairing retry history: current reachability

`build/ble-pairing-retries-sizes-001` measures ordinary advertising at54,912bytes
and scanning at59,136bytes. Their image hashes match the prior measurements
exactly, and neither retains `pairing-attempts`. The plain GATT fixture and the
fresh-pairing GATT fixture both measure122,496bytes and retain the retry policy;
the central-pairing fixture measures114,048bytes and also retains it. Equal padded
sizes do not establish equal code or isolate the retry overhead.

The plain GATT provider still references fresh-pairing implementation behind its
nullable IO-capability hook. Returning null does not discard that implementation
in these images. The explicit pairing-provider measurement above addresses this gap:
the application RPC surface is preserved, fresh pairing uses an explicit provider
module, and old IO-hook users receive a clear migration error. This is measured reachability, not a runtime-heap result.

## Timed scan rotation: optional cost isolated

`build/ble-scan-rotation-isolation-001` measures the ordinary provider at 59,136
padded bytes (snapshot 128,772), and the private provider at 63,360 (snapshot
132,862). The ordinary image discards the timed scan overload and privacy/AES;
the private image retains them and discards the fixed scan overload. Method
tables and hashes are archived alongside the images.

The trusted `run-scan` override chooses the implementation at deployment time.
This recovers the 4,224 padded bytes added by the earlier shared timer path.
The fixed and timed loops deliberately remain separate, keeping the basic call
graph small without adding per-report lambdas or another worker. These are
32-bit container measurements, not runtime heap or full-flash measurements.

## Timed scan rotation: initial shared implementation

`build/ble-scan-rotation-software-001` measures both ordinary and private scan
provider images at63,360 padded bytes. The ordinary provider excludes privacy/AES,
but grows from59,136 because its shared scan path now retains timer support.
The private provider includes privacy/AES; equal padded sizes do not mean free
crypto or equal executable code. The isolation measurement above supersedes this
initial result. No runtime heap or full-flash claim.

## Scan address-policy hook

After adding explicit scan addressing, the ordinary scan/advertising provider
still measures59,136 padded image bytes (snapshot128,630) in
`build/ble-private-scan-software-001`. Its method table excludes privacy and AES.
The changed image hash is archived; unchanged padded size is not zero added
code. This is a32-bit image comparison, not a runtime-heap or full-flash result.

## Timed non-connectable privacy provider

Measured2026-09-10 in `build/ble-private-advertising-rotation-001`, after adding
the optional timed private advertising provider. With the current host compiler
and 32-bit snapshot-to-image conversion, ordinary advertising is54,912 bytes
(snapshot120,070), while the private provider fixture is59,136 bytes
(snapshot123,496). The latter uses a public test IRK and accelerated one-second
rotation interval. Method tables exclude privacy/AES from the ordinary image
and retain them in the private image. Image hashes and tables are archived.

The4,224-byte image difference supports separate opt-in deployment. The ordinary
image retains the same padded size as the earlier measurement below; its source
and hash changed, so this is not a zero-code-cost claim. This comparison does
not measure runtime heap, complete application/flash partitions or radio behavior.
No frozen soak artifact was rebuilt or replaced.

## Service 0.20 before timed advertising rotation

Measured on 2026-09-09 in `build/ble-size-service-020` using the current host SDK
and `build/esp32-ble-current/firmware.envelope` (SHA256
`849fb8a84cacede2ca1ea290b490278214d556433d3fab8f7173815e7e43823b`).
The measurement only compiles and assembles artifacts; it does not flash hardware
or rebuild/replace the frozen soak VM or firmware.

| Configuration | Provider image | Client image | Application partition | Complete flash |
| --- | ---: | ---: | ---: | ---: |
| Advertising provider + advertising client | 54,912 B | 54,912 B | 1,522,144 B | 4,194,304 B |
| Scan/advertising provider + scan client | 59,136 B | 46,464 B | 1,522,144 B | 4,194,304 B |
| General GATT provider + scan client | 122,496 B | 46,464 B | 1,587,680 B | 4,194,304 B |
| Bond-enabled provider + scan client | 139,392 B | 46,464 B | 1,653,216 B | 4,194,304 B |
| Same bond-enabled provider + GATT client | 139,392 B | 46,464 B | 1,653,216 B | 4,194,304 B |
| General GATT provider, four receive credits + scan client | 122,496 B | 46,464 B | 1,587,680 B | 4,194,304 B |

The scan/advertising provider saves 63,360 image bytes versus the general GATT
provider. Retained method tables confirm it excludes ATT, ACL reassembly, GATT,
SMP and SC crypto. Advertising additionally excludes scanning. Both small
providers now retain `receive-credits.toit` through HCI initialization, despite
their runtime flow-control setting being zero. Their image allocation sizes
matching the earlier experiment does not mean that added code is free.

The four-credit wrapper and default GATT provider have equal padded image sizes
but different image hashes. Their snapshots are 241,266 and 241,002 bytes; this
difference includes wrapper/debug information and is not an isolated protocol
code-size measurement. Receive-credit methods are retained in both providers.
Changing the runtime setting does not remove them by tree shaking.

The exact same bond-provider image is used with both clients (SHA256
`9c0134a32b64deb554aac01728d127d73a560f4c4004ac9496bbe6f474a9a541`).
Client selection still cannot shrink a separately compiled provider. Equal client
image sizes reflect allocation granularity, not equal reachability. Snapshot,
method-table, image, envelope, partition and complete-flash artifacts are retained;
`sizes.json` and `artifact-sha256.txt` record sizes and identities.

Reproduce the compilation with the temporary optional measurement script:

```sh
python3 build/ble-temporary-python/tools/ble-service-sizes.py \
  --output build/ble-size-service-020-repeat \
  --toit build/host-ble-current/sdk/bin/toit \
  --envelope build/esp32-ble-current/firmware.envelope \
  --extra-provider build/ble-size-service-020-fixture/receive-provider.toit
```

Complete-flash files were separately extracted from each resulting envelope with
`toit tool firmware -e <envelope> extract --format=image -o <output.flash>`.
These measurements do not establish live RAM, GC costs, radio behavior, a final
supported variant matrix or a default-backend decision. The temporary script is
not an SDK or default-test dependency. Comparisons with older rows span other
source and envelope changes; do not attribute all growth to receive credits.

## Service 0.18

Rebuilt with `python3 build/ble-temporary-python/tools/ble-service-sizes.py --output build/ble-size-service-018`
after outgoing-buffer ownership/bounds fixes and the corrected `--continuous`
scan API. The same refreshed native envelope as 0.17 was used (SHA-256
`68318698331eb7bbeb3bf5f0d4a1818ca5d6f8410d1b5f1d172f25334a3c040e`).

| Configuration | Provider image | Client image | Application partition binary |
| --- | ---: | ---: | ---: |
| Advertising provider + advertising example | 54,912 B | 50,688 B | 1,522,080 B |
| Scan/advertising provider + scan client | 59,136 B | 38,016 B | 1,522,080 B |
| GATT/scan/advertising provider + scan client | 114,048 B | 38,016 B | 1,587,616 B |
| Bond-enabled provider + scan client | 130,944 B | 38,016 B | 1,587,616 B |
| Same bond-enabled provider + GATT client | 130,944 B | 46,464 B | 1,587,616 B |

All allocated image and partition sizes match the historical 0.17 experiment.
Padding means this does not establish zero code growth. Retained-method tables
confirm that advertising and scanning providers still exclude ATT, ACL, GATT,
SMP and SC crypto; advertising also excludes scanning. Client images retain only
the BLE service API/client modules, including the used buffer-copy helper.
The scan provider retains its continuous-scan implementation even though this
particular client fixture requests a finite scan. Selecting a smaller client
does not shrink the precompiled provider.

Images, snapshots, method tables, assembled envelopes and checksums are in
build/ble-size-service-018. These are compilation/size results: no image was
flashed, no runtime RAM was measured, and the active 0.16 soak is unchanged.

## Historical service 0.17

Measured after the RPC/system watch fixes, security snapshots, and bounded bond
storage/lookup work with `build/ble-temporary-python/tools/ble-service-sizes.py --output build/ble-size-service-017`.
The refreshed ESP32 envelope includes the rebuilt system snapshot (envelope
SHA256 `68318698331eb7bbeb3bf5f0d4a1818ca5d6f8410d1b5f1d172f25334a3c040e`).
The native firmware bytes are unchanged from the previous experiment.
These frozen measurements precede the later outgoing-buffer ownership fix and
pre-copy bounds; they are not rebuilt sizes of those subsequent client changes.

| Configuration | Provider image | Client image | Application partition binary |
| --- | ---: | ---: | ---: |
| Advertising provider + advertising example | 54,912 B | 50,688 B | 1,522,080 B |
| Scan/advertising provider + scan client | 59,136 B | 38,016 B | 1,522,080 B |
| GATT/scan/advertising provider + scan client | 114,048 B | 38,016 B | 1,587,616 B |
| Bond-enabled provider + scan client | 130,944 B | 38,016 B | 1,587,616 B |
| Same bond-enabled provider + GATT client | 130,944 B | 46,464 B | 1,587,616 B |

Method-table inspection again confirms that advertising and scanning variants
exclude ATT/ACL/GATT/SMP and SC crypto; advertising also excludes scanning.
The GATT provider still retains Pool_ and security implementations with its
one-session default. The bond fixture retains its used Table operations but
excludes Table.snapshot and Snapshot.find: unused preloaded multi-bond lookup
is tree-shaken even though it lives in the same module. Client method tables
still retain ServiceManager_ code; avoiding broker installation at runtime is
not the same as eliminating that code from a client image.

The identical compiled bond provider is reused with both clients. A smaller
client therefore does not shrink an already-built provider. Against 0.16, the
bond provider and GATT example each grow by 4,224 bytes; the other container and
all application-partition sizes are unchanged. This spans multiple source
changes and does not isolate any single feature's cost. Container allocation
and partition padding hide smaller code changes. Runtime RAM and whole-flash
size are outside this measurement.

Snapshots, retained-method tables, images, envelopes, binaries and hashes are
in build/ble-size-service-017. These images were assembled without flashing.
The running 0.16 soak still uses its frozen earlier firmware and system snapshot.

## Historical service 0.16

Measured the current sources after shared central ownership and recovery fixes
using `python3 build/ble-temporary-python/tools/ble-service-sizes.py --output build/ble-size-service-016`.
The controller-only native envelope includes the BLE event-queue capacity fix
(SHA256 `c52b57d171ac2815fc2a5d99cbe8dd70a1b57ac32409f9ca203bbb8a6f55c8d4`).

| Configuration | Provider image | Client image | Application partition binary |
| --- | ---: | ---: | ---: |
| Advertising provider + advertising example | 54,912 B | 50,688 B | 1,522,080 B |
| Scan/advertising provider + scan client | 59,136 B | 38,016 B | 1,522,080 B |
| GATT/scan/advertising provider + scan client | 114,048 B | 38,016 B | 1,587,616 B |
| Bond-enabled provider + scan client | 126,720 B | 38,016 B | 1,587,616 B |
| Same bond-enabled provider + GATT client | 126,720 B | 42,240 B | 1,587,616 B |

Advertising and scanning providers still exclude ATT, ACL, GATT and SMP/SC crypto
in their retained method tables. Advertising also excludes scanning. The default
one-session GATT provider retains `Pool_` construction/setup/cleanup and
`reserve-pool_`: setting the runtime session limit to one does not remove shared
central implementation code. It also still retains SMP and cryptographic methods.
These are method-table observations, not deductions from imports or defaults.

The advertising image saves 59,136 bytes (51.9%) against this GATT provider and
71,808 bytes (56.7%) against the bond provider. The exact same compiled bond
provider image is installed with both clients, so changing client reachability
does not shrink the provider. Relative to 0.13, advertising, scanning and bond
provider images each grow by 4,224 bytes; GATT and client
image sizes are unchanged. This comparison spans multiple source changes and a
new native envelope and does not isolate the cost of central sharing. Application
binaries have allocation/padding granularity; unchanged binary size is not proof
of unchanged code size. Whole-flash size and runtime RAM were not measured here.

Artifacts contain snapshots, method tables, retained-module inventories, images,
assembled envelopes, application binaries and `sizes.json`. These measurement
images were not flashed. The separately built, frozen soak deployment continues
running independently of this experiment.

## Historical service 0.13 size experiment

Measured from the service 0.13 worktree before the pending-startup cancellation
fix, with the ESP32 32-bit image format and the
same controller-only native envelope as the earlier experiment. These are
container/deployment sizes, not live RAM, heap, RPC-copy or download sizes.

| Configuration | Provider image | Client image | Application partition binary |
| --- | ---: | ---: | ---: |
| Advertising provider + advertising example | 50,688 B | 50,688 B | 1,522,080 B |
| Scan/advertising provider + scan client | 54,912 B | 38,016 B | 1,522,080 B |
| GATT/scan/advertising provider + scan client | 114,048 B | 38,016 B | 1,587,616 B |
| Bond-enabled provider + scan client | 122,496 B | 38,016 B | 1,587,616 B |
| Same bond-enabled provider + GATT client | 122,496 B | 42,240 B | 1,587,616 B |

The advertising provider saves 63,360 bytes (55.6%) relative to this general GATT
fixture and 71,808 bytes (58.6%) relative to the bond-enabled fixture. The scan
provider also exposes advertising in protocol 0.13; it is not a scan-only build.
The advertising example uses existing managed Advertisement/UUID helpers;
its client size must not be attributed solely to the service RPC API.
Application binaries include native firmware and padding, so their size changes
in larger steps than container images. Whole-flash size was not remeasured.

Retained method tables, not merely imports, verify the advertising provider has
no scanning, ATT, ACL, GATT, SMP or SC crypto methods. The scan provider retains
scanning and advertising, but likewise excludes ATT/GATT/SMP/SC crypto. Both
retain common request-service infrastructure. The general unbonded GATT fixture
still retains security, SMP and SC crypto methods: no claim of a security-free
GATT variant follows from its unbonded runtime policy. The bond-enabled fixture
additionally retains bond storage/resumption and privacy methods.

The bond-enabled provider image is reused verbatim for both clients; its SHA-256
is `18512a356fdedbdeb43f792c0ab0dae96111d6f272a8fee3efe1572768516b8b`.
The advertising provider SHA-256 is
`f43dd79488851df504d590875e4f6191a99c7fb750412a6e9d330c81e2a89713`.
Changing application reachability does not shrink an installed provider. These
measurements support choosing a smaller provider at deployment time, subject to
its advertised capabilities and the same exclusive controller ownership policy.
They do not establish a supported production variant matrix.

Reproduce with `python3 build/ble-temporary-python/tools/ble-service-sizes.py --output <new-directory>`.
The script compiles the named source fixtures, converts to 32-bit images,
records retained BLE modules, and installs the same provider/application names
into copies of one native envelope. It never flashes or runs the fixtures.
It refuses to overwrite an existing measurement directory. Artifacts are in
`build/ble-size-service-013/`; `sizes.json` records source paths, image hashes,
module inventories, SDK version and native-envelope hash. Snapshots, method
tables, images, envelopes and application binaries are retained alongside it.
Current provider RAM/GC/copy costs and additional tree-shaking boundaries remain
separate roadmap gates.

# Historical service 0.5 size experiment

Measured on 2026-09-08 using the current worktree compiler and the same
controller-only ESP32 native envelope (SDK v2.0.0-alpha.198.18+14d2e020).
These are experimental deployment choices, not a decision to support multiple
production provider variants. The measured GATT client is a representative
application, not coverage of every present or planned client API operation.

| Configuration | Provider image | Client image | Application partition binary | Whole flash image |
| --- | ---: | ---: | ---: | ---: |
| Scan provider + scan client | 54,912 B | 38,016 B | 1,522,080 B | 4,194,304 B |
| Bond/GATT/scan provider + scan client | 109,824 B | 38,016 B | 1,587,616 B | 4,194,304 B |
| Same bond/GATT/scan provider + GATT client | 109,824 B | 42,240 B | 1,587,616 B | 4,194,304 B |

The provider image saving is 54,912 bytes (50% of this bond-enabled provider).
The application-partition binary decreases by 65,536 bytes in this envelope;
alignment/padding makes this differ from the container-image delta. Complete
flash files retain their fixed 4 MiB layout. These figures are not live RAM,
managed heap or compressed download measurements.

Provider sources are `examples/ble/vhci-scan-provider.toit` and
`examples/ble/vhci-bond-service.toit`. Clients are
`examples/ble/service-scan-fixture.toit` and
`examples/ble/service-bond-values.toit`. All four snapshots were compiled from
the same worktree, converted with `snapshot-to-image -m32 --format=binary`, then
installed as the same `provider` and `application` container names into copies
of the same native envelope. The bond-enabled provider image was reused verbatim
for both client configurations. Its SHA256 is
`5d93580b66a74750015af725faedefd7c21a2a6f8a27a8733da89b9008278eaf` in both;
changing client reachability does not shrink that prebuilt provider.

The scan-only provider image SHA256 is
`1f9e1aa42c6e024fadaa10000320d41d16e7b767c7bc977f2b2ecfa18620f914`.
Its retained method table includes 50 HCI methods, 7 advertising methods,
10 scanning methods and the native/service infrastructure. It has no methods
from `attribute-server.toit`, `gatt-server.toit`, `central.toit`, `acl.toit`,
`security.toit`, `smp-*`, `sc-crypto.toit` or `sc-ecdh.toit`. The bond-enabled
provider retains the expected GATT, security, SMP, crypto and bond-store methods.
The scan-only build still includes request-service infrastructure inherited from
the shared RPC owner; imports alone were not used as evidence of exclusion.

Artifacts are in `build/ble-size-service-05/`: snapshots, 32-bit images,
method tables, envelopes, application binaries, complete flash images and
`sizes.json`. The three measurement envelopes were not flashed. Separate radio
evidence for the scan provider/application is in
`build/esp32-ble-hci/service-scan-probe/`; bond service evidence is recorded
separately in the progress log.

The saving is material for these configurations, but a supported deployment
variant still needs capability discovery, lifecycle/interoperability coverage,
release configuration and maintenance decisions. Keep the general provider as
the default experiment; no two variants may own the same controller together.
