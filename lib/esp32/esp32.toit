// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.trace show send-trace-message
import system.storage  // For toitdoc.

/**
ESP32 related functionality.
*/

ESP-RST-UNKNOWN   ::= 0 // Reset reason can not be determined.
ESP-RST-POWERON   ::= 1 // Reset due to power-on event.
ESP-RST-EXT       ::= 2 // Reset by external pin (not applicable for ESP32).
ESP-RST-SW        ::= 3 // Software reset via esp_restart.
ESP-RST-PANIC     ::= 4 // Software reset due to exception/panic.
ESP-RST-INT-WDT   ::= 5 // Reset (software or hardware) due to interrupt watchdog.
ESP-RST-TASK-WDT  ::= 6 // Reset due to task watchdog.
ESP-RST-WDT       ::= 7 // Reset due to other watchdogs.
ESP-RST-DEEPSLEEP ::= 8 // Reset after exiting deep sleep mode.
ESP-RST-BROWNOUT  ::= 9 // Brownout reset (software or hardware).
ESP-RST-SDIO      ::= 10 // Reset over SDIO.

// Enum constants from esp_sleep_source_t in esp-idf/components/esp32/include/esp_sleep.h.
WAKEUP-UNDEFINED ::= 0 // In case of deep sleep, reset was not caused by exit from deep sleep.
WAKEUP-ALL       ::= 1 // Not a wakeup cause, used to disable all wakeup sources with esp_sleep_disable_wakeup_source.
WAKEUP-EXT0      ::= 2 // Wakeup caused by external signal using RTC_IO.
WAKEUP-EXT1      ::= 3 // Wakeup caused by external signal using RTC_CNTL.
WAKEUP-TIMER     ::= 4 // Wakeup caused by timer.
WAKEUP-TOUCHPAD  ::= 5 // Wakeup caused by touchpad.
WAKEUP-ULP       ::= 6 // Wakeup caused by ULP program.
WAKEUP-GPIO      ::= 7 // Wakeup caused by GPIO (light sleep only).
WAKEUP-UART      ::= 8 // Wakeup caused by UART (light sleep only).

/**
Enters deep sleep for the specified duration (up to 24h) and does not return.
Exiting deep sleep causes the ESP32 to start over from main.

If you need to deep sleep for longer than 24h, you can chain multiple
  deep sleeps.

If the ESP32 wakes up due to the $duration expiring, then
  $reset-reason is set to $ESP-RST-DEEPSLEEP and the
  $wakeup-cause is set to $WAKEUP-TIMER.
*/
deep-sleep duration/Duration -> none:
  __deep-sleep__ duration.in-ms

/**
One of the ESP-RST-* enum values (such as $ESP-RST-POWERON) that
  indicates why the ESP32 was reset.
*/
reset-reason -> int:
  #primitive.esp32.reset-reason

/**
One of the WAKEUP-* enum values (such as $WAKEUP-TIMER) that indicates why
  the ESP32 was woken up from deep sleep.
*/
wakeup-cause -> int:
  #primitive.esp32.wakeup-cause

/**
Returns the total number of microseconds this device has been running (including deep sleep).
*/
total-run-time -> int:
  return Time.monotonic-us --no-since-wakeup

/**
Returns the total number of microseconds this device has been in deep sleep.
*/
total-deep-sleep-time -> int:
  #primitive.esp32.total-deep-sleep-time

/**
Sets the ESP32 to wake up from deep sleep if the GPIO pins in $pin-mask
  matches the mode.

If the ESP32 wakes up due to the GPIO pins, then $reset-reason is set to
  $ESP-RST-DEEPSLEEP and $wakeup-cause is set to $WAKEUP-EXT1.

If $on-any-high is true, the ESP32 will wake up if any pin in the mask is high.
If $on-any-high is false, then the behavior depends on the chip. An ESP32 will
  wake up if *all* pins in the mask are low. All other chips wake up if *any* pin in
  the mask is low.

The following GPIO pins can be used:
- ESP32: 0, 2, 4, 12-15, 25-27, 32-39
- ESP32-S2: 0-21
- ESP32-S3: 0-21

Support for the ESP32-C3 is not yet implemented.
*/
enable-external-wakeup pin-mask/int on-any-high/bool -> none:
  #primitive.esp32.enable-external-wakeup

ext1-wakeup-status pin-mask/int -> int:
  #primitive.esp32.ext1-wakeup-status

/**
Enables waking up from touchpad triggers.
The ESP32 wakes up if any configured pin has its value drop below their threshold.
Use $touchpad-wakeup-status to find which pin has triggered the wakeup.

If the ESP32 wakes up due to the touchpad, then $reset-reason is set to
  $ESP-RST-DEEPSLEEP and $wakeup-cause is set to $WAKEUP-TOUCHPAD.
*/
enable-touchpad-wakeup -> none:
  #primitive.esp32.enable-touchpad-wakeup

/**
Returns the pin number that triggered the wakeup.

Returns -1 if the wakeup wasn't caused by a touchpad.
*/
touchpad-wakeup-status -> int:
  #primitive.esp32.touchpad-wakeup-status

/**
Adjusts the real-time clock with the specified $adjustment.

The adjustment may not be visible immediately through calls to
  $Time.now in case techniques like time smearing are used to
  prevent large jumps in time.
*/
adjust-real-time-clock adjustment/Duration -> none:
  new ::= Time.now + adjustment
  set-real-time-clock_ new.s-since-epoch new.ns-part

/**
Sets the real-time clock to the new $time.

The new time is visible immediately through calls to $Time.now.
*/
set-real-time-clock time/Time -> none:
  set-real-time-clock_ time.s-since-epoch time.ns-part

set-real-time-clock_ seconds/int ns/int -> none:
  #primitive.core.set-real-time-clock

/** The WiFi MAC address of the ESP32. */
mac-address -> ByteArray:
  #primitive.esp32.get-mac-address

/**
Size of the user accessible RTC memory.

Deprecated.
*/
RTC-MEMORY-SIZE ::= 4096

/**
Constructs a $ByteArray backed by the RTC user data.

Deprecated. Use $storage.Bucket instead.

# Advanced
RTC memory is volatile memory that is powered during deep sleep. RTC memory is
  random access and significantly faster than flash memory.

It is recommended to ensure the integrity of the stored data with a checksum.

There is only one RTC memory on the device, so all tasks or processes have
  access to the same RTC memory.
*/
rtc-user-bytes -> ByteArray:
  #primitive.core.rtc-user-bytes

/**
Sends (as a system message) a report over the usage of memory at the OS level.
*/
memory-page-report -> none:
  report := memory-page-report_
  send-trace-message report

memory-page-report_ -> ByteArray:
  #primitive.esp32.memory-page-report

/**
Sends (as a system message) a detailed report over the usage of memory at the OS level.
*/
dump-heap -> none:
  report := dump-heap_ 300
  send-trace-message report

dump-heap_ slack/int -> ByteArray:
  #primitive.core.dump-heap

/**
Initializes the watchdog timer.

If there is an interval of $ms milliseconds between calls to $watchdog-reset,
  the ESP32 will reset.

Use $watchdog-deinit to disable the watchdog timer.
*/
watchdog-init --ms/int -> none:
  #primitive.esp32.watchdog-init

/**
Resets the watchdog timer.

See $watchdog-init.
*/
watchdog-reset -> none:
  #primitive.esp32.watchdog-reset

/**
Disables the watchdog timer.
*/
watchdog-deinit -> none:
  #primitive.esp32.watchdog-deinit
