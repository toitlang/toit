// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.ubjson

ESP_RST_UNKNOWN   ::= 0 // Reset reason can not be determined.
ESP_RST_POWERON   ::= 1 // Reset due to power-on event.
ESP_RST_EXT       ::= 2 // Reset by external pin (not applicable for ESP32).
ESP_RST_SW        ::= 3 // Software reset via esp_restart.
ESP_RST_PANIC     ::= 4 // Software reset due to exception/panic.
ESP_RST_INT_WDT   ::= 5 // Reset (software or hardware) due to interrupt watchdog.
ESP_RST_TASK_WDT  ::= 6 // Reset due to task watchdog.
ESP_RST_WDT       ::= 7 // Reset due to other watchdogs.
ESP_RST_DEEPSLEEP ::= 8 // Reset after exiting deep sleep mode.
ESP_RST_BROWNOUT  ::= 9 // Brownout reset (software or hardware).
ESP_RST_SDIO      ::= 10 // Reset over SDIO.

// Enum constants from esp_sleep_source_t in esp-idf/components/esp32/include/esp_sleep.h.
WAKEUP_UNDEFINED ::= 0 // In case of deep sleep, reset was not caused by exit from deep sleep.
WAKEUP_ALL       ::= 1 // Not a wakeup cause, used to disable all wakeup sources with esp_sleep_disable_wakeup_source.
WAKEUP_EXT0      ::= 2 // Wakeup caused by external signal using RTC_IO.
WAKEUP_EXT1      ::= 3 // Wakeup caused by external signal using RTC_CNTL.
WAKEUP_TIMER     ::= 4 // Wakeup caused by timer.
WAKEUP_TOUCHPAD  ::= 5 // Wakeup caused by touchpad.
WAKEUP_ULP       ::= 6 // Wakeup caused by ULP program.
WAKEUP_GPIO      ::= 7 // Wakeup caused by GPIO (light sleep only).
WAKEUP_UART      ::= 8 // Wakeup caused by UART (light sleep only).

/**
Enters deep sleep for the specified duration (up to 24h) and does not return.
Exiting deep sleep causes the ESP32 to start over from main.
*/
deep_sleep duration/Duration -> none:
  __deep_sleep__ duration.in_ms

/**
Returns one of the ESP_RST_* enum values that indicate why the ESP32 was reset.
*/
reset_reason -> int:
  #primitive.esp32.reset_reason

/**
Returns one of the WAKEUP_* enum values (such as $WAKEUP_TIMER) that indicate why the ESP32 was woken up.
*/
wakeup_cause -> int:
  #primitive.esp32.wakeup_cause

/**
Returns the total number of microseconds this device has been running (including deep sleep).
NOTE: currently boot time of FreeRTOS is not included (this might be significant).
*/
total_run_time -> int:
  #primitive.esp32.total_run_time

/**
Returns the total number of microseconds this device has been in deep sleep.
*/
total_deep_sleep_time -> int:
  #primitive.esp32.total_deep_sleep_time

/**
Set the ESP32 to wake up from deep sleep if the GPIO pins in pin_mask matches the mode.
If $on_any_high is true, the ESP32 will wake up if any pin in the mask is high.
If $on_any_high is false, the ESP32 will wake up if all pins in the mask are low.
Only the following GPIO pins can be used: 0,2,4,12-15,25-27,32-39.
*/
enable_external_wakeup pin_mask/int on_any_high/bool -> none:
  #primitive.esp32.enable_external_wakeup

ext1_wakeup_status pin_mask/int -> int:
  #primitive.esp32.ext1_wakeup_status

image_config -> Map?:
  config_data := image_config_
  if config_data[0] == 0: return null
  return (ubjson.Decoder config_data).decode

/**
Adjusts the real-time clock with the specified $adjustment.

The adjustment may not be visible immediately through calls to
  $Time.now in case techniques like time smearing are used to
  prevent large jumps in time.
*/
adjust_real_time_clock adjustment/Duration -> none:
  new ::= Time.now + adjustment
  set_real_time_clock_ new.s_since_epoch new.ns_part

/**
Sets the real-time clock to the new $time.

The new time is visible immediately through calls to $Time.now.
*/
set_real_time_clock time/Time -> none:
  set_real_time_clock_ time.s_since_epoch time.ns_part

image_config_ -> ByteArray:
  #primitive.esp32.image_config

set_real_time_clock_ seconds/int ns/int -> none:
  #primitive.core.set_real_time_clock

/** Size of the user accessible RTC memory. */
RTC_MEMORY_SIZE ::= 4096

/**
Sets the RTC user data to the given $data starting from the given $offset.

The given $data must be within bounds. That is 0 <= $offset <= $offset + data.size < $RTC_MEMORY_SIZE.

# Advanced
RTC memory is volatile memory that is powered during deep sleep. RTC memory is
  random access and significantly faster than flash memory.

It is recommended to ensure the integrity of the stored data with a checksum.
*/
set_rtc_data data offset/int=0 -> none:
  #primitive.esp32.set_rtc_user_data

/**
Gets the RTC user data in the range [$offset, $offset + $length[.

The parameters must satisfy 0 <= $offset <= + $offset + $length  < $RTC_MEMORY_SIZE.

# Advanced
RTC memory is volatile memory that is powered during deep sleep. RTC memory is
  random access and significantly faster than flash memory.

It is recommended to ensure the integrity of the stored data with a checksum.
*/
rtc_data offset/int=0 length/int=RTC_MEMORY_SIZE -> ByteArray:
  #primitive.esp32.rtc_user_data
