---
description: How to run Toit code on an ESP32 using Jaguar
---

# Running Toit code on an ESP32 with Jaguar

## Overview

Jaguar (`jag`) is the tool for deploying Toit code to ESP32 devices over WiFi.
The ESP32 must already be flashed with Jaguar firmware and connected to the same
network.

## Setting up monitoring

Before running code, start a serial monitor to capture program output:

```sh
jag monitor -a > /tmp/jag_log 2>&1 &
```

- `-a` appends to the log (doesn't clear on reconnect).
- The monitor connects to the ESP32's serial port (e.g., `/dev/ttyUSB0` or
  `/dev/ttyACM0`).
- Read output with `cat /tmp/jag_log` or `tail /tmp/jag_log`.
- The monitor process may die if the device resets or another process claims the
  serial port. Restart it if the log stays empty.
- `jag monitor` does not take any `--device` flag, but could use `--port`.

To reset the device (clears running containers):

```sh
jag monitor &
```

(Without `-a` — this triggers a reset.)

## Check whether old containers are still running
```sh
jag container --device <device-name> list
```

Uninstall them (but not "jaguar"), if necessary.


## Running a program

```sh
jag run some-program.toit --device <device-name>
```

- Programs run once and stop.
- Use `--device <name>` to select a specific device if multiple are on the
  network. Find device names with `jag scan`.

## Installing containers

Containers are persistent programs that survive reboots:

```sh
jag container install <name> some-program.toit --device <device-name>
```

- Containers start automatically on boot.
- Remove with `jag container uninstall <name> --device <device-name>`.

## Reading output

Clear the log before each run to isolate output:

```sh
cat /dev/null > /tmp/jag_log
```

Instead of sleeping a fixed duration, poll the log until the expected output
appears or the program stops/crashes:

```sh
# Poll every 2s, up to 60s, for the program to finish or hit an error
for i in $(seq 1 30); do grep -qE "program .* stopped|EXCEPTION" /tmp/jag_log && break; sleep 2; done; cat /tmp/jag_log
```

Adjust the iteration count for longer tasks (e.g., 60 iterations for cellular
modem initialization = 120s).

## Troubleshooting

- **"didn't find any Jaguar devices"**: The device may be rebooting. Wait and retry,
  or try `jag scan` to confirm it's on the network.
- **Empty log**: The monitor may have died. Check with
  `ps aux | grep "jag monitor"` and restart if needed.
- **Device name changed**: After reflashing, the device may get a new name.
  Use `jag scan` to find the current name.
