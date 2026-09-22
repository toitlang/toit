# Scan address policy

The low-level `scanning.scan` accepts `--local-random-address` in six-byte HCI
order. It validates and copies a static random or resolvable private address,
sets it before scan parameters, and selects random Own_Address_Type. Public
addressing remains the default. This overload keeps its address fixed.
Non-resolvable private addresses are not implemented here.

The policy overload accepts a scoped `--next-address` block and optional rotation
interval. It selects the initial address and a fresh one at each deadline.
Rotation pauses scanning, sets the address and re-enables scanning, preserving
one HCI report queue and cumulative drop accounting. Queued reports may predate
the address change. Controller duplicate filtering restarts after each enable.
The calling task checks timers between HCI events; report blocks must return
promptly. This avoids per-report tasks/lambdas but is not a hard realtime guarantee.

The scan service exposes the trusted-provider hook `scan-local-random-address`.
The base provider calls it once per session through its `run-scan` method.
The private provider overrides `run-scan` to select the timed overload, invoking
its address hook initially and again at `scan-address-rotation-interval` deadlines.
Applications cannot supply this policy through RPC. This deployment-level override
lets the tree shaker discard the timed scan implementation from basic services.
The optional `private-scanning-provider` owns an IRK copy and supplies fifteen-
minute rotation for scanning and non-connectable advertising. Scan intervals
must be positive and at most one hour (Core Vol3 PartC10.7.4). The service's
worker queues reports without waiting for application callbacks, so a slow
application does not suspend its rotation timer. Key persistence/distribution
and identifying advertising payload policy remain deployment responsibilities.

Timed scanning passes software and independent radio checks in
`build/ble-scan-rotation-radio-003`. Separate ESP32 provider/application containers
use one-second rotation against an independent100ms scannable advertiser.
Scan-request metadata observes85 requests across13 resolved RPAs, gaps0.840–1.142s,
and no old-address return or public peer identity. Three RPAs are observed while
the application callback blocks for three seconds. The application retains its
first response across78 full GCs, then exits inside the callback without cleanup.
The provider stops; requests cease for3.058s while advertising continues.
The coordinated harness/reference exit0 and independent adapter restoration pass.

Low-level rotation tests preserve two queued reports per pause and exactly five
cumulative drops across two rotations. They cover failed disable/address/enable,
policy failure and caller-deadline cleanup. Service tests demonstrate continued
rotation while the callback blocks, subsequent delivery and cancellation cleanup.
The separate default-interval campaign below adds long-run coverage. Broader
faults, precise clock accuracy and qualification remain open.

The authenticated private-central fixture now passes the same generated RPA
to active scanning and connection setup. Earlier private-central campaigns
proved private connection addresses, but their active scan requests still used
the public default. Those results must not be cited as private scanning evidence.

`build/ble-private-scan-resume-001` supplies independent radio evidence with
original ESP32 Board1 and Bumble0.0.234 peripheral on spare hci3. The peripheral
places FFF0 only in its scan response, so discovery requires active scanning.
Its controller enables Scan Request Received events (Core Vol4 PartE7.7.65.19).
The reference retains only scanner address metadata from that event, never raw
HCI/key traffic. It observes RPA5A:72:93:10:CB:9E, resolves it with the saved IRK
and matches it to Toit's connection address. A public request from the peer or
absence of an independently resolved private request fails the test.

The resumed peripheral RPA is4B:EC:6C:5C:93:2B. Both sides retain authenticated
bonds; no fresh pairing is allowed. Eleven protected reads, retention across11
full GCs, unchanged stored Toit candidate and reference exit0 pass. Independent
adapter restoration and preservation of the unrelated diagnostic bond pass.
This reuses the maintained-private-central-001 bond namespace; records remain
retained. That earlier campaign does not test timed scanning rotation, every service deployment,
long-run privacy or qualification.

Low-level tests assert exact random-address/active-scan command order, invalid
input before any command, recovery to a public scan after rejected address setup,
callback-error cleanup and report-slot release. Service tests additionally cover
provider selection once per session, callback failure and continuous-scan
cancellation with private addressing.

The default-interval campaign `build/ble-private-scan-default-001` now passes.
It uses the 900-second constructor default with the isolated timed-scan provider.
The application retains its exact response across 12,189 full GCs/reports and
exits after at least 1,820 board-monotonic seconds. Independent Bumble observes
12,768 resolved scan requests over three RPAs, with first-seen gaps 921.571s and
926.003s, no old-address return or public identity, and 3.333s final silence.
These gaps meet the predeclared tolerance for the documented board clock-rate
discrepancy; they do not establish a hard wall-clock timing guarantee. Provider
completion, board deep sleep, actual harness/reference exit0 and independent
adapter restoration pass. Later security changes are outside this frozen image.
