# Optional Android BLE interoperability test

## Authenticated bonded subscription fixture

`CccdActivity` exercises the separate provider/application deployment from
`examples/ble/vhci-cccd-android-provider.toit` and `examples/ble/service-cccd.toit`.
Install them as `cccd-provider` and `cccd-app`, both with no boot trigger, and use
the existing `cccd-service-pair.toit` or `cccd-service-resume.toit` supervisor.
The provider uses isolated `toit.test/cccd-android-v1` records, public test storage
keys, one peer slot and authenticated Secure Connections with peer identity
distribution. It retains its public address; Android may use private addresses.
It is a controlled fixture, not production pairing or key provisioning policy.

After the board prints `CCCD_PERSIST READY`, launch the installed test APK:

```sh
adb -s PHONE shell am start -W -n org.toitlang.bletest/.CccdActivity \
  --es address BOARD_PUBLIC_BLUETOOTH_ADDRESS --es phase pair --es run UNIQUE_RUN_ID
adb -s PHONE logcat -d -s ToitBleCccd:I '*:S'
```

Match the board's `CCCD_PERSIST NUMERIC` value to Android's system pairing dialog
before confirming. The app observes the selected device's Numeric Comparison
request and bond-state broadcasts; Android owns confirmation. It does not invoke
privileged pairing APIs. The initial phase requires no existing Android bond;
resumption requires the retained bond and never requests fresh pairing. A failed
run may leave records on either endpoint; preserve and inspect them before
choosing another phase. Do not silently remove a bond to make a retry pass.

Each phase has two connections with distinct Android clients and new Toit
provider/application containers. The first connection configures notification
and indication CCCDs and checks Service Changed configuration, which Android
may already enable. Every resumption reads all three retained values and makes
no application CCCD write. Require20 exact notifications,20 exact application
indications and one `onServiceChanged` callback per connection, along with the
board's21 actual indication confirmations and authenticated-security checks.
The final Service Changed invalidates Android's cached database; this fixture
disconnects and discovers afresh on the next connection before using attributes.

Reset into the resume supervisor, preserving NVS and the phone bond, and launch
the activity with `--es phase resume` and a new run ID. Require both peers' full
two-cycle completion records, unchanged board bond/configuration checks, GC,
actual capture exits and cleanup. A phone PASS alone does not prove the board
checks, nor does an application's no-write count exclude Android framework
writes. Full success requires the provider's retained-record checks as well.
This activity is independently scoped from the unbonded echo test below.

`verify-cccd.sh CAMPAIGN RUN_PREFIX` checks the combined `pair/` and `resume/`
logs, matched Numeric Comparison, ordered peer/provider/application completion,
GC, unchanged-record assertions, capture exits and unlocked-phone observations.
It accepts an intentional capture interruption only with all terminal assertions.
Record the enclosing runner's actual exit status and independently verify serial
and process release too. The generic echo verifier does not cover this protocol.

The first complete S3 campaign, `build/ble-android-cccd-s3-002`, passes all four
authenticated connections,80 notifications/80 application indications/four
Service Changed indications and board reset with unchanged retained records.
The initial001 attempt failed only its system-dialog button selector; the retry
passed both endpoints' empty-state guards and used identical images. No bond was
deleted. The original ESP32 comparison fails Android connection status133 before
pairing; it does not establish bonded subscription coverage on that target.

## Unbonded echo and reconnect fixture

This dedicated Android app tests the Toit `examples/ble/vhci-server.toit`
fixture using Android's own BLE stack. It requires Android 13/API 33 or newer,
Bluetooth enabled, an explicitly selected test board, and scan/connect runtime
permissions. It is not part of normal SDK builds or tests. It needs no Gradle,
Maven download or Python test dependency.

Build with an installed JDK and Android SDK containing platform 36 and build
tools 35.0.0:

```sh
ANDROID_SDK_ROOT=/path/to/android-sdk bash tests/ble-android/build.sh build/ble-android-app
adb -s PHONE install -r build/ble-android-app/ble-test.apk
adb -s PHONE shell pm grant org.toitlang.bletest android.permission.BLUETOOTH_SCAN
adb -s PHONE shell pm grant org.toitlang.bletest android.permission.BLUETOOTH_CONNECT
```

The build creates a local test signing key in its output directory. Preserve
that key to update an installed copy. This is a test-only signing identity;
do not distribute it as a release credential.

Flash the Toit fixture onto an authorized spare ESP32 using a matching SDK and
the application-only envelope workflow. Preserve unrelated stored data. Capture
serial output, start the board, and wait for `GATT_SERVER READY`. Within its
60-second accept window, run:

```sh
adb -s PHONE shell am force-stop org.toitlang.bletest
adb -s PHONE shell am start -W -n org.toitlang.bletest/.MainActivity \
  --es address BOARD_PUBLIC_BLUETOOTH_ADDRESS --es run UNIQUE_RUN_ID --ei count 100
adb -s PHONE logcat -d -s ToitBleTest:I '*:S'
```

`count` is bounded to 1–1000. `cycles` defaults to one and is bounded to 1–100.
Each cycle has a 120-second deadline; the overall deadline is 120 seconds times
the requested number of cycles. The
app filters scanning by both address and test service UUID, discovers attributes,
checks initial bytes `70 17`, enables notifications, and serializes numbered
write requests. Each exchange requires a successful write callback and an exact
notification, in either callback order. It reads the final value, disables the
CCCD, and disconnects. Callback errors, duplicates, unexpected state or data
and deadlines fail the run. No pairing or bond operation is requested.
The active test activity keeps the screen on until completion/failure and clears
that flag during cleanup. It does not change global phone power settings or
prevent an explicit screen-off action. Record the phone's awake state at launch
and termination when comparing connection failures.
The app refuses to start while the lock screen is showing, using Android's
[KeyguardManager](https://developer.android.com/reference/android/app/KeyguardManager#isKeyguardLocked()).
An awake display alone does not establish that the phone is unlocked. Foreground
results do not establish background or locked-phone BLE behavior.

Require a unique run's `PASS exchanges=100` record with both reads,
unsubscription and disconnection true, no FAIL for that run, and matching board
evidence: exactly 100 ordered ECHO records, two dynamic reads, 100 validated
writes, at least ten full GCs, retained payload checks, COMPLETE and normal deep
sleep. Archive logs from both sides, source/APK/firmware hashes, phone/board
versions and actual capture exits. A serial timeout after board completion is
an observation exit, not application failure. An app PASS alone is insufficient
for the combined hardware result. Android log timestamps need not match the
host's clock; use the run ID and sequence data to correlate them.

For repeated connection lifetimes, flash `examples/ble/vhci-reconnect.toit`
and launch with `--ei count 10 --ei cycles 20`. Each cycle closes the Android
GATT client, waits seven seconds, scans again, creates a fresh client, discovers services, verifies
the reset initial value and repeats subscription, exact exchanges and cleanup.
Require twenty ordered `CYCLE` records, `PASS exchanges=200 cycles=20`, and
twenty matching board lifetimes with ten exchanges each followed by
`VHCI_RECONNECT COMPLETE cycles=20`. Archive both logs and actual capture exits.
The default fixture reports memory per lifetime but has no warmup memory-growth
assertion; this campaign alone does not establish a long-term memory plateau.
The pause avoids rapid scan-start churn: AOSP has implemented a per-app
[five-starts-per-30-seconds limit](https://android.googlesource.com/platform/packages/apps/Bluetooth/+/250c25eb0d3dbe45bdbcc9511889844241731791/src/com/android/bluetooth/gatt/AppScanStats.java).
Device policy may differ. Stream the filtered logcat output to a file during
longer runs; repeated snapshots can lose earlier records when the ring wraps.

For a controlled reconnect diagnostic, add `--ez scan_once true`. This scans
and validates the target once, then reuses that device for subsequent connections.
Every cycle still creates and closes a fresh GATT client, retains the seven-second
pause, and requires the same reads, exchanges and cleanup. The START record
includes `scan_once`; archive it with the result. The default remains a new scan
for every cycle. A scan-once pass covers that mode only and does not explain or
replace a failure with repeated scanning. Use a stable public target address;
this mode does not test private-address rotation.

Add `--ez reuse_gatt true --ez scan_once true` for a separate client-lifetime
diagnostic. After the initial scan and connection, this mode keeps the same
Android GATT client and invokes
[`BluetoothGatt.connect()`](https://developer.android.com/reference/android/bluetooth/BluetoothGatt#connect())
after each completed disconnect and the ordinary seven-second pause. Android
documents this operation as reconnecting when the peer is available; it differs
from creating a fresh client with direct connection initiation. Discovery, both
reads, exact transfers, unsubscription and disconnect remain required on every
cycle. Final completion, failure or activity destruction closes the retained
client. Require `reuse_gatt=true` in START and nineteen ordered
`CONNECT reused-gatt=true` records for a twenty-cycle result. This is a controlled
comparison, not an automatic retry or a fix for the earlier failing mode.

The first retained-client run (`build/ble-android-reuse-gatt-001`) also fails:
nine connections/90 exact exchanges complete, then Android reports status133
before discovery on the tenth connection. The board records no tenth connection
and eventually reaches its accept deadline. Thus client recreation is not
necessary for this observed failure; its root cause remains open. The phone
stayed unlocked. Actual manually ended captures1/130 and the failed20-cycle
criterion are preserved in the campaign record.

The first scan-once comparison (`build/ble-android-scan-once-001`) fails on the
seventh connection after six complete lifetimes against the unchanged ESP32
revision3 diagnostic image. Android reports status133; the board later reaches
its accept deadline. Repeated scanning is therefore not necessary to trigger
this observed failure. It remains an unresolved interoperability failure.

The first run is archived in `build/ble-android-echo-001`: Pixel 10, Android 17
(API 37), central role against original ESP32 with the Toit host. It covers
unencrypted scanning, discovery, reads, write requests, notifications and
disconnect. It does not establish Android peripheral role, security, bonding,
reconnection, every MTU, load limits or full Bluetooth conformance.

The app uses the value-bearing read/notification callbacks and write methods
documented in [BluetoothGatt](https://developer.android.com/reference/android/bluetooth/BluetoothGatt)
and [BluetoothGattCallback](https://developer.android.com/reference/android/bluetooth/BluetoothGattCallback).
Callbacks run on its main handler; there is only one outstanding GATT operation.
To remove the test app afterwards, use `adb -s PHONE uninstall org.toitlang.bletest`.

For new completed campaigns captured with bounded timeouts, verify both logs:

```sh
bash tests/ble-android/verify.sh CAMPAIGN UNIQUE_RUN_ID 10 20
```

The verifier requires actual capture exits 124, both peers' terminal assertions,
ordered cycles and exact numbered board payloads. It rejects a phone PASS without
matching board evidence. If captures were manually stopped, review their actual
exits separately rather than changing exit files to satisfy this verifier.

Reconnect campaigns 001 and 002 are failures, not accepted coverage: the first
stalls scanning after five lifetimes; the second returns Android connection
status 133 after two lifetimes despite pacing scan starts. The diagnostic
`examples/ble/vhci-reconnect-diagnostics.toit` variant records bounded HCI headers
and public connection/advertising statuses for investigation. It never records
raw ACL, SMP or key payloads. It has the same twenty-by-ten exchange target.

`examples/ble/vhci-reconnect-persistent.toit` is a controlled comparison that
keeps one controller/host alive for the twenty connections instead of closing
and recreating it after each disconnect. Use the same `count=10`, `cycles=20`
and verifier. Each new GATT session resets the echo value, performs both dynamic
reads, checks every write and retained payload, and ends before the next accept.
The terminal board record includes `persistent=true`. Record which controller
lifetime model was tested; these results are not interchangeable.

For controller metadata with that same persistent lifetime, call
`vhci-reconnect-diagnostics.run --persistent` from a wrapper instead. It retains
only the first64 HCI framing headers and bounded public connection/disconnection
and advertising-command statuses. It omits raw ACL/SMP/key payloads. A traced
pass does not explain a failed plain run; preserve both. The unlocked-phone
comparison007 still fails with Android status133 on its fourth connection after
three complete lifetimes. The board reaches its next accept deadline; the phone
remains unlocked at the terminal observation. Controller cause remains open.
