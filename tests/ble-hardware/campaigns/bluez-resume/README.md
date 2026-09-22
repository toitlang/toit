# BlueZ bond resumption campaign

Pairs the original ESP32 (central, Toit host) with a BlueZ peripheral, then
resumes the bond on a fresh boot without pairing. One image serves both phases:
`provider.toit` pairs when the isolated namespace has no record and resumes
otherwise.

```sh
C=build/ble-resume-features-001; T=build/host/sdk/bin/toit; mkdir -p $C
$T compile -s -o $C/provider.snapshot tests/ble-hardware/campaigns/bluez-resume/provider.toit
$T compile -s -o $C/client.snapshot tests/ble-hardware/fixtures/service-central-values.toit
$T compile -s -o $C/observer.snapshot tests/ble-hardware/linux-security-events.toit
cp build/esp32-ble-current/firmware.envelope $C/application.envelope
$T tool firmware -e $C/application.envelope container install ble-provider $C/provider.snapshot
$T tool firmware -e $C/application.envelope container install ble-client $C/client.snapshot
# Fresh start: clear NVS on the board and the BlueZ bond for the test identity.
$T tool firmware -e $C/application.envelope flash --port /dev/serial/by-id/<original ESP32> --partition empty:nvs=65536
busctl --system call org.bluez /org/bluez/hci0 org.bluez.Adapter1 RemoveDevice o /org/bluez/hci0/dev_C8_3A_F2_23_31_51
tests/ble-hardware/campaigns/bluez-resume/run-phase.sh pair
tests/ble-hardware/campaigns/bluez-resume/run-phase.sh resume
```

Pass: the reference log ends with `"event": "passed"`, the board prints
`CENTRAL_FRESH COMPLETE resumed=true candidate-retained=true` in the resume
phase, and the observer reports `authentication-failed=0`. The reference is
`tests/ble-interop/bluez-gatt-server.py` (optional Python, dbus-fast); resume
mode registers a rejecting NoInputNoOutput agent so BlueZ requests the security
properties of a Just Works peer.
