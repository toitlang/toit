# Independent BLE connection peer

This ESP-IDF program uses Bluedroid on the ESP32 DevKitC. It advertises
`toit-esp-peer` for the unchanged `../ble-connect-nrf5340.toit` test. It requires
only USB power and the console; it leaves the wired peripheral fixture pins
unused. Restore `../wiring-esp32.toit` after radio testing.

It is a connection peer, not the GATT/notification fixture. Use
`../ble-peer-esp32.toit` for the latter. There is no application GATT database
here. Very short links can end before application GATT callbacks run; use the
controller's `BT_HCI: hcif disc complete` log entries to count those closures.
The application callbacks also log longer links and restart advertising when
they receive a disconnect. There is no artificial connection delay or polling
loop to recover advertising.

From the repository root, with the pinned ESP-IDF environment activated:

```sh
idf.py -C tests/hw/nrf5340/ble-connect-esp32 \
  -B "$PWD/build/nrf5340-ble/bluedroid-peer" \
  -D SDKCONFIG="$PWD/build/nrf5340-ble/bluedroid-peer/sdkconfig" build
```

Flash using the generated `flash_args` in that build directory and the
identified ESP32 port. Capture its console before resetting the nRF test. The
nRF must report all four cycle passes, `BLE adapter close during connection
PASS`, `NRF5340 BLE CONNECTION PASS`, and `VM teardown complete`. The peer must
observe 37 remote disconnects: 32 immediate connect/close cycles, four links
closed by adapter teardown, and the final link closed by VM teardown.

## NimBLE early-disconnect defect

The same test originally failed after one link with the Toit ESP32 peer built
against ESP-IDF `b7a900d409643ef47d37528d70177888a8520421` and its NimBLE revision
`0225775e49669cd4f070400908f73718bddce83b`.

In this NimBLE revision, peripheral connection success is reported only after
remote version/feature discovery. `ble_gap_conn_broken` suppresses the
disconnect callback if that discovery has not finished. Advertising has
already stopped, so Toit's peripheral receives neither event and cannot
restart advertising. A diagnostic at this branch recorded:

```text
NIMBLE suppressed disconnect handle=0 reason=531 advertising=0
```

Reason 531 is NimBLE's HCI error encoding for remote user termination (`0x13`).
The ESP32 heartbeat continued while the next nRF connection timed out. The
diagnostic changed logging only.

`nimble-early-disconnect.patch` reports a failed connection event on that path,
after releasing the connection, using its saved callback and argument. This
lets the existing Toit callback restart advertising. It adds no nRF delay and
does not change the successful-connection or ordinary-disconnect paths.

The patch is an explicit test-dependency correction, not an automatically
applied change to the ESP-IDF submodule. To reproduce the corrected Toit peer:

```sh
git -C third_party/esp-idf/components/bt/host/nimble/nimble apply \
  "$PWD/tests/hw/nrf5340/ble-connect-esp32/nimble-early-disconnect.patch"
# Rebuild the Toit ESP32 firmware and package ble-peer-esp32.toit as documented
# in the parent README. Run the unchanged nRF connection test against it.
git -C third_party/esp-idf/components/bt/host/nimble/nimble apply --reverse \
  "$PWD/tests/hw/nrf5340/ble-connect-esp32/nimble-early-disconnect.patch"
```

Rebuild the ESP32 firmware after reversing the patch before packaging another
peer. Keep both console logs and identify which host stack and dependency
revision were used. A pass with this patch does not establish interoperability
with the unmodified affected NimBLE version.

## Hardware results

The unchanged nRF image passes the complete connection suite with this
Bluedroid peer (`build/nrf5340-ble/early-disconnect/bluedroid-nrf.log`). Its
console records 37 remote-user-termination HCI events (`bluedroid-console.log`),
including the final VM teardown. The application GATT connection counters stay
at zero for these very short links; they are not the qualification evidence.

The original Toit/NimBLE peer also passes all four cycles after applying the
patch (`fixed-nrf.log`, `fixed-console.log` in the same directory). The full
notification/indication suite then passes four adapter cycles with that same
peer, including empty values and overflow recovery (`notify-hardware.log`). The vendor
source was restored byte-for-byte afterward; the patch is not left applied to
the project's ESP-IDF checkout.

The nRF build with automatic MTU exchange enabled also passes this full suite
(`build/nrf5340-ble/auto-mtu/connect-hardware.log`). The matching
`connect-peer-console.log` again records 37 remote-user-termination HCI events.
Unlike the earlier run, application callbacks also observe these links;
the final HCI disconnect remains the evidence for VM teardown.
