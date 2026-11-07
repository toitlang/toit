# ESP8285 AT datagram extension

This experimental extension targets the Pico W-2023's 1 MiB ESP8285. It keeps
Espressif AT commands and UART transport. It is not a replacement protocol.
Version 1 passed receive boundary, metadata, empty-packet, oversize-discard and
socket-reuse tests on hardware. Version 2 adds empty UDP transmission and passed
both host socket tests and the public adapter's binary/empty/boundary hardware
fixture on October 6 (Pico application 348; smoke restore 349 passed).

The cellular ESP8285 adapter uses passive TCP, this extension for passive UDP,
and escaped `CIPSENDEX` for binary sends. Stock ESP8266 AT passive UDP can merge
or truncate queued packets. Stock zero-length `CIPSEND` returns ERROR;
`CIPSENDEX` acknowledges an empty terminated send, but the echo fixture receives
no reply. Do not silently treat either as successful empty-packet delivery.

## Commands

Set `CIPRECVMODE=1` before using the extension. Do not let active AT reception
consume the same UDP socket concurrently.

- `AT+TOITUDP?` returns `+TOITUDP:2,1460`, then OK.
- `AT+TOITUDP=<link-id>` returns one packet as
  `+TOITUDP:<length>,"<IPv4>",<port>,<binary>`, followed by CRLF and OK. An empty
  packet has length zero and still has sender metadata.
- An empty receive queue returns `+TOITUDP:-1`; a datagram exceeding 1,460 bytes
  is consumed and returns `+TOITUDP:-2`. Both are followed by OK.
- `AT+TOITUDPEMPTY=<link-id>,"<IPv4>",<port>` sends one zero-length UDP datagram.
  OK means `sendto` accepted that datagram; it does not imply peer delivery.
- Invalid link IDs, non-UDP sockets and malformed parameters return ERROR.

The commands use the exported `esp_at_get_socket_by_link_id` symbol. They do not
modify the closed AT core or clear its pending-notification flags. A reader must
poll when waiting for UDP, even if an earlier `+IPD` was already handled.

## Source and build

Use [Espressif ESP-AT](https://github.com/espressif/esp-at) commit
`5249c31d1df78c68622b33ffa9fd82b9991c28be`, with its ESP8266 RTOS SDK at
`ff16a35c362047b47c0b3d29c02ef9755b623447`. The bundled AT core reports
`2.2.2.0 (6cdf453)`. The tested build uses Python 3.10.20 and the Espressif
`esp-2020r3-49-gd5524c1` Xtensa LX106 GCC 8.4.0 toolchain.

Apply `vendor.patch` to a clean pinned checkout, then copy `udp-receive.c` to
`components/at/src/toit_udp_receive.c`. The patch registers the extension,
selects 40 MHz DOUT flash, and configures UART TX1/RX3 at 115200 without flow
control. These are ESP8285 GPIO numbers; they connect to RP2040 GP1/GP0.
The selected SDK defaults use a 26 MHz crystal and a six-entry UDP mailbox.
Install the pinned checkout's Python requirements in a Python 3.10 environment.
Put that environment and the Xtensa toolchain's `bin` directory on PATH.

From the ESP-AT checkout, with `IDF_PATH` pointing to its `esp-idf` directory:

```sh
export IDF_TARGET=esp8266
export ESP_AT_PROJECT_PLATFORM=PLATFORM_ESP8266
export ESP_AT_MODULE_NAME=ESP8266_1MB
export ESP_AT_PROJECT_PATH="$PWD"
export SILENCE=0
python "$IDF_PATH/tools/idf.py" reconfigure build
```

Verify the resulting `sdkconfig` has a 26 MHz crystal, UART flow control zero,
1 MiB DOUT flash and a 40 MHz flash clock. The application is `build/esp-at.bin`
and must fit the 917,504-byte application partition at `0x20000`.

For an already provisioned board with the matching bootloader, partition table
and UART parameters, update only that application partition after a full flash
backup. The factory image changes modem settings and is not interchangeable
with an application-only update. The RP2040 recovery loader is separate.
Installation requires the modem in ROM download mode; its BOOT and reset
controls are not wired remotely on the current board.

## Validation

From the Toit repository root:

```sh
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -DTOIT_AT_HOST_TEST -Itests/hw/rp2040/modem/esp-at \
  tools/rp2040/esp-at/udp-receive.c \
  tests/hw/rp2040/modem/esp-at/udp-receive-test.c -o /tmp/esp-at-udp-test
/tmp/esp-at-udp-test
```

The harness uses real loopback sockets. Hardware tests are
`tests/hw/rp2040/modem/udp-extension-probe.toit` (receive protocol) and
`network-binary.toit` (public adapter API, including empty transmission).
Run them with the Wi-Fi helper fixture, retaining the exact modem image, adapter
source and logs. The [investigation report](../../../docs/rp2040-esp8285-wifi-investigation.md)
records what has actually passed. Version 2 and the integrated adapter have
since passed TLS, concurrent TCP/UDP stress, service lifecycle, and full-size
OTA with a changed image and verified SHA-256. Dynamic-compression OTA required
fixing allocation-failure notifications in the helper ESP32's TCP stack.
Interrupted-send tests verify a closed interface and awakened readers; their
reconnect step uses explicit cleanup at a known payload boundary. They do not
prove automatic resynchronization after arbitrary interrupted payloads.
