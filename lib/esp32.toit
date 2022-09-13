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
Sets the ESP32 to wake up from deep sleep if the GPIO pins in pin_mask matches the mode.
If $on_any_high is true, the ESP32 will wake up if any pin in the mask is high.
If $on_any_high is false, the ESP32 will wake up if all pins in the mask are low.
Only the following GPIO pins can be used: 0,2,4,12-15,25-27,32-39.
*/
enable_external_wakeup pin_mask/int on_any_high/bool -> none:
  #primitive.esp32.enable_external_wakeup

ext1_wakeup_status pin_mask/int -> int:
  #primitive.esp32.ext1_wakeup_status

/**
Enables waking up from touchpad triggers.
The ESP32 wakes up if any configured pin has its value drop below their threshold.
Use $touchpad_wakeup_status to find which pin has triggered the wakeup.
*/
enable_touchpad_wakeup -> none:
  #primitive.esp32.enable_touchpad_wakeup

/**
Returns the pin number that triggered the wakeup.

Returns -1 if the wakeup wasn't caused by a touchpad.
*/
touchpad_wakeup_status -> int:
  #primitive.esp32.touchpad_wakeup_status

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
Constructs a $ByteArray backed by the RTC user data.

# Advanced
RTC memory is volatile memory that is powered during deep sleep. RTC memory is
  random access and significantly faster than flash memory.

It is recommended to ensure the integrity of the stored data with a checksum.

There is only one RTC memory on the device, so all tasks or processes have
  access to the same RTC memory.
*/
rtc_user_bytes -> ByteArray:
  #primitive.esp32.rtc_user_bytes

/**
Returns a report over the usage of memory at the OS level.

The returned list has at least four elements.  The first is a byte
  array describing the allocation types in each page.  The second is
  a byte array giving the percentage fullness of each page.  Pages are
  normally 4096 bytes large.  The third is the base address of the heap,
  corresponding to the address of the block described in the 0th element
  of each byte array.

For very large heaps the returned list may contain more than four
  elements.  Each group of three entries in the array consists of
  two byte arrays and a base address as described above.

The last entry in the returned list is the page size.

For the first byte array in each triplet, each byte is a bitmap.

* $MEMORY_PAGE_MALLOC_MANAGED: Indicates the page is part of the malloc-managed memory.
* $MEMORY_PAGE_TOIT: Allocated for the Toit heap.
* $MEMORY_PAGE_EXTERNAL: Contains at least one allocation for external (large) Toit strings and byte arrays.
* $MEMORY_PAGE_TLS: Contains at least one allocation for TLS and other cryptographic uses.
* $MEMORY_PAGE_BUFFERS: Contains at least one allocation for network buffers.
* $MEMORY_PAGE_MISC: Contains at least one miscellaneous or unknown allocation.
* $MEMORY_PAGE_MERGE_WITH_NEXT: Indicates that this page and the next page are part of a large multi-page allocation.

Pages that are not part of the malloc heap, because the system is using them
  for something else will have a zero in both byte arrays, indicating 0% fullness
  and no registered allocations.
*/
memory_page_report -> List:
  #primitive.esp32.memory_page_report

print_memory_page_report -> none:
  report := memory_page_report
  granularity := report[report.size - 1]
  k := granularity >> 10
  scale := ""
  for i := 232; i <= 255; i++: scale += "$TERMINAL_SET_BACKGROUND_$(i)m "
  scale += TERMINAL_RESET_COLORS_
  print "┌────────────────────────────────────────────────────────────────────────┐"
  print "│$(%2d k)k pages.  All pages are $(%2d k)k, even the ones that are shown wider       │"
  print "│ because they have many different allocations in them.                  │"
  print "│   X  = External strings/bytearrays.        B  = Network buffers.       │"
  print "│   W  = TLS/crypto.                         M  = Misc. allocations.     │"
  print "│   🐱 = Toit managed heap.                  -- = Free page.             │"
  print "│        Fully allocated $scale Completely free page.  │"
  print "└────────────────────────────────────────────────────────────────────────┘"
  for i := 0; i < report.size; i += 3:
    uses := report[i]
    if uses is int: continue
    fullnesses := report[i + 1]
    base := report[i + 2]
    lowest := uses.size
    highest := 0
    for j := 0; j < uses.size; j++:
      if uses[j] != 0 and fullnesses[j] != 0:
        lowest = min lowest j
        highest = max highest j
    if lowest > highest: continue
    print "0x$(%08x base + lowest * granularity)-0x$(%08x base + (highest + 1) * granularity)"
    print_line_ uses fullnesses "┌"  "──┬"  "───"  "──┐" false
    print_line_ uses fullnesses "│"    "│"    " "    "│" true
    print_line_ uses fullnesses "└"  "──┴"  "───"  "──┘" false

print_line_ uses/ByteArray fullnesses/ByteArray open/string allocation_end/string allocation_continue/string end/string is_data_line/bool -> none:
  line := []
  for i := 0; i < uses.size; i++:
    use := uses[i]
    if use == 0 and fullnesses[i] == 0: continue
    symbols := ""
    if use & MEMORY_PAGE_TOIT != 0: symbols = "🐱"
    if use & MEMORY_PAGE_BUFFERS != 0: symbols = "B"
    if use & MEMORY_PAGE_EXTERNAL != 0: symbols += "X"
    if use & MEMORY_PAGE_TLS != 0: symbols += "W"  // For WWW.
    if use & MEMORY_PAGE_MISC != 0: symbols += "M"  // For WWW.
    previous_was_unmanaged := i == 0 or (uses[i - 1] == 0 and fullnesses[i - 1] == 0)
    if previous_was_unmanaged:
      line.add open
    fullness := fullnesses[i]
    if fullness == 0:
      symbols = "--"
    while symbols.size < 2:
      symbols += " "
    if is_data_line:
      white_text := fullness > 50  // Percent.
      background_color := TERMINAL_LIGHT_GREY_ - (24 * fullness) / 100
      background_color = max background_color TERMINAL_DARK_GREY_
      if fullness == 0:
        background_color = TERMINAL_WHITE_
      else if use & MEMORY_PAGE_TOIT != 0:
        background_color = TERMINAL_TOIT_HEAP_COLOR_

      line.add "$TERMINAL_SET_BACKGROUND_$(background_color)m"
             + "$TERMINAL_SET_FOREGROUND_$(white_text ? TERMINAL_WHITE_ : TERMINAL_DARK_GREY_)m"
             + symbols + TERMINAL_RESET_COLORS_
    next_is_unmanaged := i == uses.size - 1 or (uses[i + 1] == 0 and fullnesses[i + 1] == 0)
    line_drawing := ?
    if next_is_unmanaged:
      line_drawing = end
    else if use & MEMORY_PAGE_MERGE_WITH_NEXT != 0:
      line_drawing = allocation_continue
    else:
      line_drawing = allocation_end
    if symbols.size > 2 and not is_data_line and symbols != "🐱":
      // Pad the line drawings on non-data lines to match the width of the
      // data.
      first_character := line_drawing[0..utf_8_bytes line_drawing[0]]
      line_drawing = (first_character * (symbols.size - 2)) + line_drawing
    line.add line_drawing
  print
      "  " + (line.join "")

TERMINAL_SET_BACKGROUND_ ::= "\x1b[48;5;"
TERMINAL_SET_FOREGROUND_ ::= "\x1b[38;5;"
TERMINAL_RESET_COLORS_   ::= "\x1b[0m"
TERMINAL_WHITE_ ::= 231
TERMINAL_DARK_GREY_ ::= 232
TERMINAL_LIGHT_GREY_ ::= 255
TERMINAL_TOIT_HEAP_COLOR_ ::= 174  // Orange-ish.

/**
Bitmap mask for $memory_page_report.
Indicates at least part of the page is managed by malloc.
*/
MEMORY_PAGE_MALLOC_MANAGED  ::= 1 << 0

/**
Bitmap mask for $memory_page_report.
Indicates the page was allocated for the Toit heap.
*/
MEMORY_PAGE_TOIT            ::= 1 << 1

/**
Bitmap mask for $memory_page_report.
Indicates the page contains at least one allocation for external (large)
  Toit strings and byte arrays.
*/
MEMORY_PAGE_EXTERNAL        ::= 1 << 2

/**
Bitmap mask for $memory_page_report.
Indicates the page contains at least one allocation for TLS and other
  cryptographic uses.
*/
MEMORY_PAGE_TLS             ::= 1 << 3

/**
Bitmap mask for $memory_page_report.
Indicates the page contains at least one allocation for network buffers.
*/
MEMORY_PAGE_BUFFERS         ::= 1 << 4

/**
Bitmap mask for $memory_page_report.
Indicates the page contains at least one miscellaneous or unknown allocation.
*/
MEMORY_PAGE_MISC            ::= 1 << 5

/**
Bitmap mask for $memory_page_report.
Indicates that this page and the next page are part of a large multi-page
  allocation.
*/
MEMORY_PAGE_MERGE_WITH_NEXT ::= 1 << 6
