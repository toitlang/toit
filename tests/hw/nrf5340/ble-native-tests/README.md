# Native GATT callback tests

These tests compile the production `src/resources/ble_zephyr_server.cc` against
the pinned Zephyr host stack and run it on `native_sim/native/64`, without a
Bluetooth controller. They use the same kernel callback mutex as the firmware.
The VM notification hook is replaced by a small test owner; the GATT definitions,
access callbacks, UUID conversion and Zephyr database operations are unchanged.

From the repository root, after the existing Zephyr setup:

```sh
CCACHE_DIR=$PWD/.cache/ccache \
ZEPHYR_BASE=$PWD/.cache/zephyr-workspace/zephyr \
ZEPHYR_TOOLCHAIN_VARIANT=host \
cmake -S tests/hw/nrf5340/ble-native-tests \
  -B build/nrf5340-ble/native-tests -G Ninja \
  -DBOARD=native_sim/native/64 \
  -DPython3_EXECUTABLE=$PWD/.cache/zephyr-venv/bin/python
CCACHE_DIR=$PWD/.cache/ccache \
  cmake --build build/nrf5340-ble/native-tests -j8
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  timeout 45s build/nrf5340-ble/native-tests/zephyr/zephyr.exe
```

The seven cases check:

- Actual wire encoding of 16-, 32- and 128-bit UUID declarations, handle ordering,
  CCC placement and descriptor boundaries.
- Stored reads at offsets through 512 bytes, fragment sizes from one byte to
  512 bytes, empty values, and rejected offsets without buffer overwrite.
- Queued writes, independent buffer ownership, overflow reporting, and recovery
  across 50 rounds, without changing the separately stored read value.
- Rejected prepared writes, unsupported access modes and CCC bit combinations.
- Independent notification/indication encryption flags, plaintext reads,
  declaration masking, rejection of unencrypted CCC enables, and the actual
  Zephyr send-permission check on private attribute copies. This simulator has
  SMP disabled; encrypted success and live connections require the board test.
- Detaching and freeing an owner while retaining native definitions, plus
  registration/unregistration/re-registration across 100 database lifetimes.
- Two competing Zephyr threads: detachment must wait while a write callback
  holds the mutex; later accesses must reject the detached owner. Runs 50 times.

ASan and UBSan are enabled in `prj.conf`, with errors treated as fatal. Leak
detection is disabled because of the sandbox tracing and native simulator's
documented GCC/64-bit LeakSanitizer limitations. The initial message about a
missing Bluetooth device is expected: `bt_enable` is never called.

These are callback/database tests, not a simulated radio or a simulated Toit VM.
They do not cover ATT packet dispatch, HCI initialization, advertising or
connection state machines, indication acknowledgements, VM event delivery,
allocation failures, or hardware timing. The paired board tests remain required.
