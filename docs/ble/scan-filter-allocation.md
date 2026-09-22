# Allocation in advertised service UUID matching

`advertising.advertises-service` now compares UUID16 and UUID32 entries directly
inside the managed advertising buffer. It expands the requested UUID once and
checks Bluetooth base-UUID compatibility before comparing short entries. The
scan callback does not need a new object or escaping closure per UUID entry.
UUID128 entries retain native whole-array comparison using a managed slice.

The filter still validates the entire AD sequence after finding a match. Bad
lengths or incomplete UUID entries return false; zero-length termination retains
its existing semantics. Service data and solicitation fields do not become UUID
lists. Existing ownership and report retention semantics are unchanged.

## Measured tradeoff

`build/ble-scan-uuid-allocation-001` contains the original source, benchmark,
candidate comparisons, final source hashes and test logs. The reference module
changes only the archived source's relative HCI import to its absolute package
name, allowing old and new implementations to run in the same process. Each
case warms up 100 checks and measures 10,000 successful checks, repeated three
times. These are Linux VM microbenchmarks, not ESP32 or radio throughput results.

| Advertised list / target | Allocated bytes before / after, warmed round | Elapsed before / after over three final rounds |
| --- | --- | --- |
| Fourteen UUID16 entries / UUID16 | 12,880,128 / 320,128 | 54.1–55.7ms / 13.9–15.9ms |
| Seven UUID32 entries / UUID32 | 6,720,128 / 320,128 | 27.6–28.2ms / 15.1–15.6ms |
| One UUID128 entry / UUID128 | 320,128 / 320,128 | 2.58–2.68ms / 2.89–3.34ms |
| One UUID128 entry / equivalent UUID16 | 880,128 / 640,128 | 4.49–4.96ms / 4.41–4.76ms |

The short-list cases reduce measured allocation by approximately 97.5% and 95.2%.
Counters include fixed benchmark/statistics overhead and are not live-memory
or GC-pause measurements. The UUID128 case shows a modest CPU cost in this
sample; no universal throughput improvement is claimed. An earlier candidate
removed its slice too, but interpreted byte comparisons were substantially
slower, so native comparison was retained for that width.

Regression coverage in `ble-hci-test.toit` checks every direction of equivalent
16-/32-/128-bit representations, nonzero upper UUID32 octets, every altered base
UUID byte, exact custom UUID128 matches and existing malformed AD behavior.
Release load limits remain a separate roadmap gate; target microbenchmarks follow.

## ESP32 and ESP32-S3 measurements

`build/ble-scan-uuid-target-001` runs both implementations in one application
image on spare original ESP32 Board1 and non-PSRAM ESP32-S3 Board2. Both complete
all 24 measurements and enter deep sleep. Every measurement records one full GC
and one compacting GC between its statistics snapshots. Input and target bytes
remain unchanged after each old/new pair. No case increases allocation.

The following are 10,000-check measurements; time uses the awake clock. Allocation
is the same on both 32-bit targets, apart from first-round bookkeeping overhead.

| List / target | Warmed allocated bytes before → after | ESP32 elapsed before → after | ESP32-S3 elapsed before → after |
| --- | --- | --- | --- |
| Fourteen UUID16 / UUID16 | 7,640,064 → 240,064 | 6.90–7.26s → 1.812–1.814s | 6.23–6.73s → 1.531–1.533s |
| Seven UUID32 / UUID32 | 4,000,064 → 240,064 | 3.754–3.772s → 1.746s | 3.365–3.366s → 1.443s |
| One UUID128 / UUID128 | 160,064 → 160,064 | 0.354s → 0.370–0.371s | 0.306s → 0.318s |
| One UUID128 / UUID16 | 520,064 → 400,064 | 0.629s → 0.619s | 0.562s → 0.544s |

Short-list allocation reductions are approximately 96.9% and 94%. The full
UUID128 case retains a measured 4–5% CPU cost, so this remains a tradeoff rather
than a universal speedup. The two versions share a diagnostic image with no
BLE controller open; these results do not measure scan throughput, whole-provider
memory, GC pause duration, or code/firmware size. Application-only flashes
preserve bond/program storage; live soak resources are untouched.
