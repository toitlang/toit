# Timed advertising privacy

Service0.22 live-update interaction has software serialization coverage. A
maintained optional independent observer now checks updates while the private
provider rotates every second: all payload phases must retain repeated reports
and use at least three resolvable addresses, including empty payloads. Identity,
rotation/continuity/cessation and per-lifetime command-count controls pass.
Independent radio validation passes on original ESP32 in
`build/ble-private-advertising-updates-002`: six updates/eight application GC
phases, six resolving RPAs per phase/stream,20 rotations per stream,42 balanced
enable/disable commands and over nine seconds final scannable silence. Both
containers finish; reference/runner/supervisor exit0 and adapter/port cleanup
are verified. Attempt001's obsolete relay failed before board startup and is
retained. This accelerated one-second test does not validate default900-second
timing, private connectable advertising or private pending-update client death.
Earlier rotation-only radio evidence below retains its separate scope.

The optional `service.private-advertising-provider.Provider` implements timed
RPA changes for the exclusive non-connectable advertising service. It owns an
IRK copy and selects a fresh address for each session and timer expiration.
The application API remains `with-advertising`; trusted provider code selects
the address policy and interval. The default is fifteen minutes.

Core6.3 Vol3 PartC10.7.3 (page1444) requires a host-based private broadcaster to
generate a new private address at TGAP(private_addr_int). The recommended value
in PartC17 is fifteen minutes. Advertising pauses while the host disables it,
sets the new random address and enables it again. Deadlines use monotonic time
from address generation; setup and command delays are not added to every timer
period. Scheduling/command latency is still present; this is not a hard realtime
guarantee. No extra worker, external receive buffer or GC finalizer is introduced.

Ordinary advertising keeps its public default. Its new provider hooks also
support an explicitly selected static/RPA address without a timer. Rotation
requires a random address and a positive interval. The private subclass owns a
copy of its key, avoids repeating its previous RPA and does not persist keys.
It does not rewrite advertising data. Deployments requiring unlinkability must
avoid stable identifying payloads and coordinate their changing data policy.
Importing ordinary advertising does not import the optional AES/RPA generator.
Current service0.22 measurements give59,136 padded bytes for both ordinary and
private advertising. Method tables exclude privacy/AES from the ordinary image
and retain them in the private one; different snapshots/hashes confirm different
code despite equal padded sizes. These are not runtime heap measurements.
See [current deployment sizes](service-sizes.md). The earlier rotation campaign's
54,912/59,136-byte measurements remain valid for its frozen images.

The implementation deliberately uses only non-connectable legacy advertising
(types2/3). No connection can arise while this session disables advertising or
changes its address, and the controller is exclusive. The same loop must not be
applied to `Central.accept`: the legacy disable/connection race described in
[mixed-role services](mixed-role-services.md) is still unresolved. Connectable
advertising and established-link privacy retain their separate gates. Scanning
now has independent timed-rotation evidence in [scan privacy](scanning-privacy.md).

`tests/ble-service-private-advertising-test.toit` checks two timer rotations in
one controller lifetime, exact disable/set-address/enable order, distinct RPAs
resolving under the original copied key, and retained samples across requested
GC. It also checks failures at disable/address/enable, cancellation while waiting,
and cancellation with a missing set-address reply. The latter reports the
bounded command timeout and closes the controller; it is not a clean stop.
Four additional real client-process exit cases now cover the timer wait and
accepted-but-unanswered Disable, Set Random Address, and Enable commands.
`build/ble-private-rotation-exit-replay-001` verifies that admission stays busy
while reader teardown is held, then a replacement client uses the same provider
with a fresh resolving RPA. GC, no further old-transport commands, replacement
stop and session release are checked. Normal/optimized/sanitizer execution and
three focused CTests pass, with no production change. This is scripted controller
evidence; native pending-command exit now also passes as described below.
Provider crash and external SIGKILL remain separate gates. Ordinary advertising
exit regressions remain required.

`build/ble-private-rotation-exit-native-001` (2026-09-22) passes on ESP32 Board2
and S3 Board1 using the same maintained `private-rotation-exit.toit` snapshot.
Separate client processes die with actual successful Disable/Set Random Address/
Enable replies held. The provider witnesses pending-at-death, releases each
session/reader and admits a replacement. A fourth client advertises/stops normally.
Exact selected command counts, six distinct resolving submitted RPAs and eleven
full-GC checks pass per board. Both runners exit0 and boards sleep, without a
production fix. This establishes native controller cleanup with separate heaps
in one container. Independent scanning now also passes for these interruption
cases as described below. Separate-container/provider crash coverage stays open.

`build/ble-private-rotation-radio-001` uses unchanged board images and independent
Bumble scanning. ESP32/S3 produce131/128 exact fixture reports, observed RPA counts
1,1,2,1 across the four clients, and no returning old stage/address. The second
address programmed at the Set Random Address hold never advertises; the address
at the Enable hold appears5/4 times. Observed inter-client gaps are at least
1.301/1.154s, with7.178/7.135s final quiet. All board lifecycle/count/GC checks pass.
These are sampled observer-local gaps, not calibrated RF stopping latency.

Both references exit0 and boards sleep. ESP32's runner preserves a name-only
restoration failure: BlueZ reapplied its configured name after user-channel exit.
The exact original live name was restored with MAC/precondition/readback checks;
the stored alias was not written. S3's runner includes that restoration and exits0.
Full captured public adapter state and USB policy match afterward, and ports/
lease release. No flash, phone, bond operation or production BLE change.

Independent radio validation passes in `build/ble-private-advertising-radio-003`:
separate provider/application containers on original ESP32 Board1, one-second
rotation and eight seconds each of non-scannable and scannable advertising.
Bumble observes63/63 advertisements and62 scan responses, nine distinct RPAs
per category, exact payloads and correct modes. Address changes span each phase,
first-observation gaps are0.761–1.120 seconds, and old RPAs never reappear after
rotation. The inter-session stop gap is3.328 seconds and final silence3.252 seconds.
Both application phases retain data across9 full GCs; both containers complete.
The reference exits0 and independent adapter/bond-preservation checks pass.

The initial radio001 fixture failed because it passed a specification-order IRK
to Bumble's SMP-order resolver. A separate Core AppendixD.7 vector check verifies
the conversion. Radio002 passes address/mode/count checks; radio003 adds the
timing and old-address checks above. Failed evidence remains archived.

Abrupt client-exit radio coverage passes in
`build/ble-private-advertising-exit-001`. Two separate applications exit from inside
`with-advertising` without executing their cleanup blocks. The first exit stops
non-scannable advertising while the provider remains available to the second
client; the second subsequently advertises in scannable mode and exits. The
independent scanner receives 69/64 advertisements and 64 scan responses, nine
resolved RPAs per category, exact payloads and no old-address return. Address
changes occur at 0.744–1.118s gaps; inter-session silence is 3.267s and final
silence 3.057s. Each client retains data across nine full GCs. The provider
terminates, the board sleeps, reference/harness exit0, and independent adapter
restoration and unrelated bond preservation pass. This covers abrupt Toit
process exit, not external SIGKILL or provider crashes.

Other privacy roles and clock accuracy retain separate gates. Neither these
tests nor this feature establish full GAP privacy qualification or unlinkability
when payloads reveal identity.

The default-interval fixture now passes in
`build/ble-private-advertising-default-001`: separate containers, no rotation
argument override, 1,820 one-second waits/full GCs per advertising mode. The
predeclared independent checks require at least two observed rotations and
5,000 exact reports in each category, verified stopping and adapter restoration.
After the default scanning campaign completed and independently restored hci3,
this run started at 2026-09-10 01:46:41UTC on spare Board2. Terminal observation
confirms13942 non-scannable advertisements,13973 scannable advertisements and
13330 scan responses, with three independently resolving RPAs per category.
First-seen rotation gaps are920.957–924.238 seconds, within the predeclared
825–975 second bounds that acknowledge the board-clock discrepancy. Exact modes,
payloads and scan-response addresses pass, with no old/public address return.
Inter-session silence is about3.388 seconds; final scannable/response silence
exceeds3.66 seconds. Both modes retain data across1821 full GCs.

Client/provider completion and deep sleep, actual harness/reference exit0,
supervisor child0/restoration verified and independent management/DBus checks
all pass. Board monitor exits1 after intentional interruption following completion.
The same adapter is powered with autosuspend disabled and the unrelated Board2
bond remains paired, disconnected and untrusted. Artifacts and hashes are archived;
adapter and Board2 are released. This does not establish exact wall-clock timing,
connectable privacy or later pairing/registry changes.
