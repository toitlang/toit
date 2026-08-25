// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.sha256 as crypto
import encoding.json

import ar

DESCRIPTION-FORMAT ::= "toit-inspector-description"
DESCRIPTION-VERSION ::= 1
ENVELOPE-ENTRY ::= "\$inspector.json"
OWNERSHIP-FORMAT ::= "toit-native-ownership"
OWNERSHIP-VERSION ::= 1

/** Builds an inspector description for an exact firmware ELF. */
create runtime-layout/Map elf/ByteArray source/string -> Map:
  return {
    "format": DESCRIPTION-FORMAT,
    "format-version": DESCRIPTION-VERSION,
    "generator": "gdb-dwarf-v1",
    "firmware": {
      "source": source,
      "elf-size": elf.size,
      "elf-sha256": hex-digest (crypto.sha256 elf),
    },
    "runtime-layout": runtime-layout,
    "native-ownership": native-ownership-v1 runtime-layout,
  }

/** Validates and returns an inspector description. */
validate input/any -> Map:
  if not input is Map: throw "INVALID_INSPECTOR_DESCRIPTION"
  input-format := input.get "format"
  input-version := input.get "format-version"
  if input-format != DESCRIPTION-FORMAT or
      input-version != DESCRIPTION-VERSION:
    throw "INVALID_INSPECTOR_DESCRIPTION"
  firmware-value := input.get "firmware"
  if not firmware-value is Map: throw "INVALID_INSPECTOR_DESCRIPTION"
  firmware/Map := firmware-value
  elf-size := firmware.get "elf-size"
  elf-sha/string? := firmware.get "elf-sha256"
  if not elf-size is int or elf-size <= 0 or
      not elf-sha or elf-sha.size != 64:
    throw "INVALID_INSPECTOR_DESCRIPTION"
  runtime-layout-value := input.get "runtime-layout"
  if not runtime-layout-value is Map: throw "INVALID_INSPECTOR_DESCRIPTION"
  runtime-layout/Map := runtime-layout-value
  runtime-format := runtime-layout.get "format"
  runtime-version := runtime-layout.get "format-version"
  if runtime-format != "toit-runtime-layout" or runtime-version != 1:
    throw "INVALID_INSPECTOR_DESCRIPTION"
  ownership-value := input.get "native-ownership"
  if not ownership-value is Map: throw "INVALID_INSPECTOR_DESCRIPTION"
  ownership/Map := ownership-value
  ownership-format := ownership.get "format"
  ownership-version := ownership.get "format-version"
  ownership-decoders := ownership.get "decoders"
  if ownership-format != OWNERSHIP-FORMAT or
      ownership-version != OWNERSHIP-VERSION or
      not ownership-decoders is List:
    throw "INVALID_INSPECTOR_DESCRIPTION"
  validate-native-ownership ownership
  return input

validate-native-ownership ownership/Map -> none:
  decoders := list-of-maps ownership "decoders" 64
  decoder-ids := {:}
  decoders.do: | decoder/Map |
    id := required-string decoder "id"
    version := decoder.get "version"
    if version is not int or version <= 0 or decoder-ids.contains id:
      throw "INVALID_INSPECTOR_DESCRIPTION"
    decoder-ids[id] = true

  event-sources := list-of-maps ownership "event-source-owned-fields" 128
  event-sources.do: | event-source/Map |
    required-string event-source "dynamic-type"
    fields := list-of-maps event-source "fields" 64
    fields.do: | field/Map |
      required-string field "name"
      required-string field "kind"

  validate-string-recipes ownership "toit-mutex-slots" ["symbol", "component", "kind"]
  validate-string-recipes ownership "direct-static-roots" ["symbol", "component", "kind"]
  validate-string-recipes
      ownership
      "resource-pools"
      ["symbol", "elements-offset", "component", "kind"]
  validate-string-recipes ownership "static-locks" ["symbol", "component", "kind"]
  validate-string-recipes ownership "constant-locks" ["constant", "component", "kind"]
  if ownership.contains "physical-memory-regions":
    validate-string-recipes
        ownership
        "physical-memory-regions"
        [
          "id", "component", "kind", "storage", "start", "end",
          "release-detection", "evidence",
        ]

validate-string-recipes ownership/Map key/string required/List -> none:
  recipes := list-of-maps ownership key 256
  recipes.do: | recipe/Map |
    required.do: | field/string | required-string recipe field

list-of-maps owner/Map key/string maximum/int -> List:
  value := owner.get key
  if value is not List or value.size > maximum:
    throw "INVALID_INSPECTOR_DESCRIPTION"
  result/List := value
  result.do: | entry |
    if entry is not Map: throw "INVALID_INSPECTOR_DESCRIPTION"
  return result

required-string owner/Map key/string -> string:
  value := owner.get key
  if value is not string or value.is-empty or value.size > 256:
    throw "INVALID_INSPECTOR_DESCRIPTION"
  return value

/** Verifies that an inspector description belongs to the provided ELF. */
validate-for-elf input/any elf/ByteArray -> Map:
  result := validate input
  firmware/Map := result["firmware"]
  elf-sha := hex-digest (crypto.sha256 elf)
  if firmware["elf-size"] != elf.size or
      firmware["elf-sha256"] != elf-sha:
    throw "INSPECTOR_DESCRIPTION_ELF_MISMATCH"
  return result

/** Reads the inspector description stored in an envelope, if present. */
from-envelope envelope/ByteArray -> Map?:
  reader := ar.ArReader.from-bytes envelope
  result/Map? := null
  elf/ByteArray? := null
  while entry := reader.next:
    if entry.name == ENVELOPE-ENTRY:
      result = validate (json.decode entry.content)
    else if entry.name == "\$firmware.elf":
      elf = entry.content
  if not result: return null
  if not elf: throw "INSPECTOR_DESCRIPTION_ELF_NOT_IN_ENVELOPE"
  return validate-for-elf result elf

/** Describes the native ownership decoders and their firmware declarations. */
native-ownership-v1 runtime-layout/Map?=null -> Map:
  result := {
    "format": OWNERSHIP-FORMAT,
    "format-version": OWNERSHIP-VERSION,
    "decoders": [
      {"id": "toit-gc-metadata", "version": 1},
      {"id": "toit-gc-spare-space", "version": 1},
      {"id": "toit-scheduler-threads", "version": 1},
      {"id": "toit-event-sources", "version": 1},
      {"id": "newlib-stdio", "version": 1},
      {"id": "gpio-statics", "version": 1},
      {"id": "platform-statics", "version": 1},
      {"id": "freertos-tasks", "version": 1},
    ],
    "event-source-owned-fields": [{
      "dynamic-type": "toit::TimerEventSource",
      "fields": [{"name": "timer_changed_", "kind": "condition-variable"}],
    }, {
      "dynamic-type": "toit::SystemEventSource",
      "fields": [{"name": "run_cond_", "kind": "condition-variable"}],
    }, {
      "dynamic-type": "toit::EventQueueEventSource",
      "fields": [
        {"name": "stop_", "kind": "freertos-queue"},
        {"name": "gpio_queue_", "kind": "freertos-queue"},
        {"name": "queue_set_", "kind": "freertos-queue"},
      ],
    }, {
      "dynamic-type": "toit::LwipEventSource",
      "fields": [{"name": "call_done_", "kind": "condition-variable"}],
    }, {
      "dynamic-type": "toit::TlsEventSource",
      "fields": [{"name": "sockets_changed_", "kind": "condition-variable"}],
    }],
    "toit-mutex-slots": [
      {
        "symbol": "toit::ObjectMemory::spare_chunk_mutex_",
        "component": "toit-gc",
        "kind": "spare-chunk-mutex",
      },
      {
        "symbol": "toit::OS::resource_mutex_",
        "component": "toit-runtime",
        "kind": "resource-registry-mutex",
      },
      {
        "symbol": "toit::OS::process_mutex_",
        "component": "toit-runtime",
        "kind": "process-registry-mutex",
      },
      {
        "symbol": "toit::OS::tls_mutex_",
        "component": "tls",
        "kind": "runtime-tls-mutex",
      },
      {
        "symbol": "toit::OS::global_mutex_",
        "component": "toit-runtime",
        "kind": "global-runtime-mutex",
      },
    ],
    "direct-static-roots": [
      {"symbol": "s_log_tags", "component": "logging", "kind": "cached-log-tags"},
      {"symbol": "s_keys", "component": "pthread", "kind": "thread-local-storage-keys"},
    ],
    "resource-pools": [
      {
        "symbol": "toit::uart_ports",
        "elements-offset": "toit::uart_ports::ELEMENTS_OFFSET",
        "component": "uart",
        "kind": "uart-port-pool",
      },
      {
        "symbol": "toit::spi_host_devices",
        "elements-offset": "toit::spi_host_devices::ELEMENTS_OFFSET",
        "component": "spi",
        "kind": "spi-host-pool",
      },
    ],
    "static-locks": [
      {"symbol": "api_lock_sem", "component": "networking", "kind": "lwip-api-lock"},
      {"symbol": "g_lwip_protect_mutex", "component": "networking", "kind": "lwip-core-lock"},
      {"symbol": "s_fd_table_lock", "component": "vfs", "kind": "file-descriptor-table-lock"},
      {"symbol": "s_partition_list_lock", "component": "flash", "kind": "partition-list-lock"},
      {"symbol": "s_flash_op_mutex", "component": "flash", "kind": "flash-operation-lock"},
      {"symbol": "s_log_mutex", "component": "logging", "kind": "log-lock"},
    ],
    "constant-locks": [
      {
        "constant": "esp-idf::spi-flash::MMU_LOCK_SLOT_ADDRESS",
        "component": "flash",
        "kind": "flash-mmu-lock",
      },
      {
        "constant": "esp-idf::uart-vfs::WRITE_LOCK_SLOT_ADDRESS",
        "component": "vfs",
        "kind": "uart-write-lock",
      },
      {
        "constant": "esp-idf::usb-serial-jtag-vfs::WRITE_LOCK_SLOT_ADDRESS",
        "component": "vfs",
        "kind": "usb-serial-jtag-write-lock",
      },
    ],
    "physical-memory-regions": physical-memory-regions runtime-layout,
  }
  regions/List := result["physical-memory-regions"]
  if not regions.is-empty:
    decoders/List := result["decoders"]
    decoders.add {"id": "physical-memory-regions", "version": 1}
  return result

physical-memory-regions runtime-layout/Map? -> List:
  if not runtime-layout: return []
  result := []
  add-symbol-region
      result
      runtime-layout
      "bluetooth-host-data"
      "bluetooth host data"
      "_bt_data_start"
      "_bt_data_end"
  add-symbol-region
      result
      runtime-layout
      "bluetooth-controller-data"
      "bluetooth controller data"
      "_bt_controller_data_start"
      "_bt_controller_data_end"
  add-symbol-region
      result
      runtime-layout
      "bluetooth-host-bss"
      "bluetooth host BSS"
      "_bt_bss_start"
      "_bt_bss_end"
  add-symbol-region
      result
      runtime-layout
      "bluetooth-controller-bss"
      "bluetooth controller BSS"
      "_bt_controller_bss_start"
      "_bt_controller_bss_end"

  reserved := [
    ["bluetooth-rom-data", "Bluetooth ROM data", "BTDM"],
    ["bluetooth-controller-em-shared-0", "Bluetooth controller EM shared 0", "BTDM"],
    ["bluetooth-controller-em-ble", "Bluetooth controller EM BLE", "BLE"],
    ["bluetooth-controller-em-shared-1", "Bluetooth controller EM shared 1", "BTDM"],
    ["bluetooth-controller-em-classic", "Bluetooth controller EM Classic", "Classic"],
    ["bluetooth-rom-bss", "Bluetooth ROM BSS", "BTDM"],
    ["bluetooth-rom-misc", "Bluetooth ROM miscellaneous", "BTDM"],
  ]
  constants/Map := runtime-layout.get "constants" --if-absent=: {:}
  reserved.size.repeat: | index |
    start-key := "esp-idf::bt::reserved-region-$(index)-start"
    end-key := "esp-idf::bt::reserved-region-$(index)-end"
    if not constants.contains start-key or not constants.contains end-key:
      continue.repeat
    spec/List := reserved[index]
    start/int := constants[start-key]
    end/int := constants[end-key]
    if end <= start: continue.repeat
    result.add {
      "id": spec[0],
      "name": spec[1],
      "component": "bluetooth",
      "kind": "sdk-reserved",
      "storage": "internal-ram",
      "start": hex-address start,
      "end": hex-address end,
      "release-detection": "allocator-registry",
      "release-mode": spec[2],
      "evidence": "esp-idf-btdm-region-table",
    }
  return result

add-symbol-region
    result/List
    runtime-layout/Map
    id/string
    name/string
    start-symbol/string
    end-symbol/string
    -> none:
  symbols/Map := runtime-layout.get "symbols" --if-absent=: {:}
  start-entry := symbols.get start-symbol
  end-entry := symbols.get end-symbol
  if not start-entry or not end-entry: return
  if not (start-entry.get "present" --if-absent=: false) or
      not (end-entry.get "present" --if-absent=: false):
    return
  start := parse-hex-address start-entry["address"]
  end := parse-hex-address end-entry["address"]
  if end <= start: return
  result.add {
    "id": id,
    "name": name,
    "component": "bluetooth",
    "kind": "static-linked",
    "storage": "internal-ram",
    "start": hex-address start,
    "end": hex-address end,
    "release-detection": "allocator-registry",
    "evidence": "elf-linker-symbols:$start-symbol:$end-symbol",
  }

parse-hex-address value/string -> int:
  if not value.starts-with "0x": throw "INVALID_INSPECTOR_DESCRIPTION"
  return int.parse value[2..] --radix=16

hex-address value/int -> string:
  return "0x$(value.to-string --radix=16)"

hex-digest bytes/ByteArray -> string:
  result := ""
  bytes.do: | byte/int |
    if byte < 16: result += "0"
    result += byte.to-string --radix=16
  return result
