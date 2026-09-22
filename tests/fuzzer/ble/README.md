# Native BLE queue fuzz target

`queue.cc` exercises the production `PacketQueue<8, 1029>` with a separate
owned-packet reference queue. It checks framing, terminal errors, reserved scan
slots/drop counters, overflow, exact copying, allocation failure/retry ordering
and queue/high-water accounting after each operation. It uses exact-sized input
and output allocations so sanitizers can detect boundary violations.

This is a sequential operation fuzzer. It does not test concurrent interleavings,
ESP32 callback registration, HCI command state, or Toit ATT/SMP parsers.

Build and run from the repository root (requires Clang's libFuzzer runtime):

```sh
mkdir -p build/ble-queue-fuzz
clang++ -std=c++11 -g -O1 -fno-omit-frame-pointer \
  -fsanitize=fuzzer,address,undefined tests/fuzzer/ble/queue.cc \
  -o build/ble-queue-fuzz/queue-fuzz
cp -r tests/fuzzer/ble/corpus build/ble-queue-fuzz/corpus
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
  /bin/sh -c '"$@"; ble_exit=$?; printf "%s\n" "$ble_exit" > build/ble-queue-fuzz/child.exit; exit "$ble_exit"' sh \
  build/ble-queue-fuzz/queue-fuzz -seed=130013 -runs=100000 \
  -max_len=4096 -rss_limit_mb=1024 -timeout=10 \
  -artifact_prefix=build/ble-queue-fuzz/ build/ble-queue-fuzz/corpus
```

The checked-in corpus contains valid event/ACL, overflow, scan reserve, short
header, null-pointer and maximum-sized ACL sequences. Mutate a build-directory
copy, preserving the starting corpus. Replay any saved failure by passing that
file instead of the corpus directory. Seed alone does not ensure identical
mutations across compiler/runtime versions; retain generated inputs and logs.

The initial 100,000-run campaign completed with ASan/UBSan/leak detection and
exit zero. Its runtime reported about 2.5 GiB RSS at startup; the default
libFuzzer RSS limit aborted the first attempt before completion. The documented
4 GiB limit is above that observed baseline. Neither run is evidence of the
queue's memory footprint. LeakSanitizer requires process inspection unavailable
in the restricted sandbox used for this work.

A later current-source campaign, `build/ble-queue-fuzz-current-003`, completes
one million inputs under ASan/UBSan/LSan, with exit zero and538MiB terminal RSS.
The direct-launch attempt reported5664MiB immediately and hit its4GiB limit;
the same binary and initial corpus through the small shell above start at45MiB
and pass with a1GiB limit. This supports inherited peak-RSS accounting as the
startup discrepancy. Keep the shell's post-command exit recording so it forks
the tested executable rather than replacing itself. Preserve failed runs instead
of simply increasing memory limits; these host RSS values are not embedded
queue footprint measurements.
