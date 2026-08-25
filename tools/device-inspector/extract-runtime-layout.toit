// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import fs
import host.file
import host.pipe

TYPE-SPECS ::= [
  ["toit::VM", ["scheduler_", "event_manager_", "nop_event_source_"]],
  ["toit::Scheduler", [
    "num_processes_", "num_threads_", "max_threads_",
    "gc_waiting_for_preemption_", "gc_cross_processes_", "threads_", "groups_",
  ]],
  ["toit::Thread", ["name_", "handle_"]],
  ["toit::ThreadData", ["handle", "terminated"]],
  ["toit::EntropyMixer", ["context_", "mutex_"]],
  ["toit::ProgramHeapMemory", ["memory_mutex_"]],
  ["mbedtls_entropy_context", ["accumulator"]],
  ["mbedtls_md_context_t", ["md_ctx", "hmac_ctx"]],
  ["toit::Mutex", ["sem_"]],
  ["toit::ConditionVariable", ["mutex_"]],
  ["toit::EventSourceManager", ["event_sources_"]],
  ["toit::EventSource", ["mutex_", "name_"]],
  ["toit::TimerEventSource", ["timer_changed_"]],
  ["toit::SystemEventSource", ["run_cond_"]],
  ["toit::EventQueueEventSource", ["stop_", "gpio_queue_", "queue_set_"]],
  ["toit::LwipEventSource", ["call_done_"]],
  ["toit::TlsEventSource", ["sockets_changed_"]],
  ["struct tskTaskControlBlock", [
    "pxTopOfStack", "pxStack", "pcTaskName", "pxEndOfStack", "xTLSBlock",
  ]],
  ["struct _reent", ["_reserved_8"]],
  ["struct _glue", ["_next", "_niobs", "_iobs"]],
  ["struct __sFILE", ["_bf", "_ub", "_lb", "_lock"]],
  ["struct __sbuf", ["_base"]],
  ["struct sys_mbox_s", ["os_mbox"]],
  ["struct xLIST", ["uxNumberOfItems", "xListEnd"]],
  ["struct xMINI_LIST_ITEM", ["pxNext"]],
  ["struct xLIST_ITEM", ["pxNext", "pvOwner"]],
  ["struct esp_event_loop_instance", ["queue", "task", "mutex"]],
  ["toit::ProcessGroup", ["id_", "program_", "memory_", "processes_"]],
  ["toit::Process", [
    "id_", "state_", "priority_", "program_heap_address_",
    "program_heap_size_", "object_heap_", "resource_groups_",
  ]],
  ["toit::ResourceGroup", [
    "process_", "event_source_", "resources_",
  ]],
  ["toit::Resource", [
    "resource_group_", "state_", "object_notifier_",
  ]],
  ["toit::ObjectNotifier", ["process_", "object_", "message_"]],
  ["toit::HeapRoot", ["obj_"]],
  ["toit::FinalizerNode", ["key_"]],
  ["toit::CallableFinalizerNode", ["lambda_"]],
  ["toit::WeakMapFinalizerNode", []],
  ["toit::ToitFinalizerNode", []],
  ["toit::VmFinalizerNode", []],
  ["toit::SimpleResourceGroup", []],
  ["toit::IntResource", ["id_"]],
  ["toit::TimerResourceGroup", []],
  ["toit::Timer", ["timeout_"]],
  ["toit::ObjectNotifyMessage", ["notifier_", "queued_"]],
  ["toit::ObjectHeap", [
    "program_", "task_", "gc_count_", "full_gc_count_", "two_space_heap_",
    "external_memory_", "global_variables_", "object_notifiers_",
    "external_roots_", "runnable_finalizers_",
    "registered_callback_finalizers_", "registered_vm_finalizers_",
  ]],
  ["toit::TwoSpaceHeap", ["old_space_", "semi_space_"]],
  ["toit::OldSpace", [
    "tracking_allocations_", "compacting_", "used_", "promoted_track_",
  ]],
  ["toit::SemiSpace", []],
  ["toit::Space", ["top_", "limit_", "chunk_list_"]],
  ["toit::Chunk", [
    "start_", "end_", "scavenge_pointer_", "compaction_top_",
  ]],
  ["toit::GcMetadata", [
    "metadata_", "metadata_size_", "mark_bits_bias_",
    "cumulative_mark_bits_bias_",
  ]],
  ["toit::Program", ["class_bits", "global_variables", "bytecodes"]],
  ["toit::Program::Table<toit::Object*>", ["length_"]],
  ["toit::List<unsigned short>", ["data_", "length_"]],
  ["toit::List<unsigned char>", ["data_", "length_"]],
  ["DoubleLinkedList<toit::ProcessGroup, 1>", []],
  ["DoubleLinkedListElement<toit::ProcessGroup, 1>", ["next_"]],
  ["DoubleLinkedListElement<toit::Chunk, 1>", ["next_"]],
  ["LinkedList<toit::Process, 1>", []],
  ["LinkedListElement<toit::Process, 1>", ["next_"]],
  ["LinkedList<toit::SchedulerThread, 1>", []],
  ["LinkedListElement<toit::SchedulerThread, 1>", ["next_"]],
  ["LinkedList<toit::EventSource, 1>", []],
  ["LinkedListElement<toit::EventSource, 1>", ["next_"]],
  ["LinkedList<toit::ResourceGroup, 1>", []],
  ["DoubleLinkedList<toit::Resource, 1>", []],
  ["DoubleLinkedListElement<toit::Resource, 1>", ["next_"]],
  ["DoubleLinkedList<toit::ObjectNotifier, 1>", []],
  ["DoubleLinkedListElement<toit::ObjectNotifier, 1>", ["next_"]],
  ["DoubleLinkedList<toit::HeapRoot, 1>", []],
  ["DoubleLinkedListElement<toit::HeapRoot, 1>", ["next_"]],
  ["LinkedFifo<toit::FinalizerNode, 1>", []],
  ["LinkedListElement<toit::FinalizerNode, 1>", ["next_"]],
  ["heap_t", ["start", "end", "heap", "next.sle_next"]],
  ["struct multi_heap_info", [
    "end_of_heap_structure", "arenas", "number_of_pages", "page_base",
    "highest_address", "pages",
  ]],
  ["arena_t", ["previous", "next"]],
  ["header_t", ["size_", "tag"]],
  ["Page", ["status", "tag"]],
]

// These types exist only on some ESP-IDF targets. Their absence must not make
// an otherwise valid firmware description impossible to build.
OPTIONAL-TYPE-SPECS ::= [
  ["gdma_platform_t", ["groups"]],
]

SYMBOL-NAMES ::= [
  "toit::VM::current_",
  "toit::ObjectMemory::allocated_",
  "toit::ObjectMemory::spare_chunk_",
  "toit::ProgramHeapMemory::instance_",
  "toit::GcMetadata::singleton_",
  "registered_heaps",
  "pxCurrentTCBs",
  "pxReadyTasksLists",
  "xDelayedTaskList1",
  "xDelayedTaskList2",
  "xPendingReadyList",
  "xSuspendedTaskList",
  "xTasksWaitingTermination",
  "s_default_loop",
  "__sglue",
  "toit::gpio_pins",
  "gpio_context",
  "toit::EntropyMixer::instance_",
  "tcpip_mbox",
  "api_lock_sem",
  "g_lwip_protect_mutex",
  "s_fd_table_lock",
  "s_partition_list_lock",
  "s_flash_op_mutex",
  "s_log_mutex",
  "__sf",
  "toit::ObjectMemory::spare_chunk_mutex_",
  "toit::OS::resource_mutex_",
  "toit::OS::process_mutex_",
  "toit::OS::tls_mutex_",
  "toit::OS::global_mutex_",
  "s_log_tags",
  "s_keys",
  "toit::uart_ports",
  "toit::spi_host_devices",
]

OPTIONAL-SYMBOL-NAMES ::= [
  "s_crypto_sha_aes_lock",
]

BT-SYMBOL-NAMES ::= [
  "_bt_data_start",
  "_bt_data_end",
  "_bt_controller_data_start",
  "_bt_controller_data_end",
  "_bt_bss_start",
  "_bt_bss_end",
  "_bt_controller_bss_start",
  "_bt_controller_bss_end",
]

CONSTANT-SPECS ::= [
  [
    "toit::uart_ports::ELEMENTS_OFFSET",
    "p/x (unsigned long)&toit::uart_ports.elements_ - (unsigned long)&toit::uart_ports",
  ],
  [
    "toit::spi_host_devices::ELEMENTS_OFFSET",
    "p/x (unsigned long)&toit::spi_host_devices.elements_ - (unsigned long)&toit::spi_host_devices",
  ],
  [
    "esp-idf::spi-flash::MMU_LOCK_SLOT_ADDRESS",
    "p/x (unsigned long)&s_mmu_ctx.mutex",
  ],
  [
    "esp-idf::uart-vfs::WRITE_LOCK_SLOT_ADDRESS",
    "p/x (unsigned long)&'uart_vfs.c'::s_context[0].write_lock",
  ],
  [
    "toit::gpio_pins::ELEMENTS_OFFSET",
    "p/x (unsigned long)&toit::gpio_pins.elements_ - (unsigned long)&toit::gpio_pins",
  ],
  [
    "esp-idf::gpio_context::ISR_FUNC_OFFSET",
    "p/x (unsigned long)&gpio_context.gpio_isr_func - (unsigned long)&gpio_context",
  ],
  [
    "toit::EventSource::MANAGER_LIST_ELEMENT_OFFSET",
    "p/x (unsigned long)(static_cast<LinkedListElement<toit::EventSource, 1>*>((toit::EventSource*)0x1000)) - 0x1000",
  ],
  [
    "toit::TimerEventSource::THREAD_OFFSET",
    "p/x (unsigned long)(static_cast<toit::Thread*>((toit::TimerEventSource*)0x1000)) - 0x1000",
  ],
  [
    "toit::EventQueueEventSource::THREAD_OFFSET",
    "p/x (unsigned long)(static_cast<toit::Thread*>((toit::EventQueueEventSource*)0x1000)) - 0x1000",
  ],
  [
    "toit::TlsEventSource::THREAD_OFFSET",
    "p/x (unsigned long)(static_cast<toit::Thread*>((toit::TlsEventSource*)0x1000)) - 0x1000",
  ],
  [
    "toit::SchedulerThread::SCHEDULER_LIST_ELEMENT_OFFSET",
    "p/x (unsigned long)(static_cast<LinkedListElement<toit::SchedulerThread, 1>*>((toit::SchedulerThread*)0x1000)) - 0x1000",
  ],
  [
    "freertos::CURRENT_TCB_COUNT",
    "p/x sizeof(pxCurrentTCBs) / sizeof(pxCurrentTCBs[0])",
  ],
  [
    "freertos::READY_LIST_COUNT",
    "p/x sizeof(pxReadyTasksLists) / sizeof(pxReadyTasksLists[0])",
  ],
  [
    "freertos::PENDING_READY_LIST_COUNT",
    "p/x sizeof(xPendingReadyList) / sizeof(xPendingReadyList[0])",
  ],
  ["toit::Stack::HEADER_SIZE", "p/x toit::Stack::HEADER_SIZE"],
  ["toit::Stack::LENGTH_OFFSET", "p/x toit::Stack::LENGTH_OFFSET"],
  ["toit::Stack::TOP_OFFSET", "p/x toit::Stack::TOP_OFFSET"],
  ["toit::Stack::TRY_TOP_OFFSET", "p/x toit::Stack::TRY_TOP_OFFSET"],
  [
    "toit::Stack::PENDING_STACK_CHECK_METHOD_OFFSET",
    "p/x toit::Stack::PENDING_STACK_CHECK_METHOD_OFFSET",
  ],
  ["toit::ByteArray::LENGTH_OFFSET", "p/x toit::ByteArray::LENGTH_OFFSET"],
  ["toit::ByteArray::EXTERNAL_ADDRESS_OFFSET", "p/x toit::ByteArray::EXTERNAL_ADDRESS_OFFSET"],
  ["toit::ByteArray::EXTERNAL_TAG_OFFSET", "p/x toit::ByteArray::EXTERNAL_TAG_OFFSET"],
  ["toit::String::INTERNAL_LENGTH_OFFSET", "p/x toit::String::INTERNAL_LENGTH_OFFSET"],
  ["toit::String::EXTERNAL_LENGTH_OFFSET", "p/x toit::String::EXTERNAL_LENGTH_OFFSET"],
  ["toit::String::EXTERNAL_ADDRESS_OFFSET", "p/x toit::String::EXTERNAL_ADDRESS_OFFSET"],
  [
    "toit::ResourceGroup::PROCESS_LIST_NEXT_OFFSET",
    "p/x (unsigned long)(static_cast<LinkedListElement<toit::ResourceGroup, 1>*>((toit::ResourceGroup*)0x1000)) - 0x1000",
  ],
  [
    "toit::Resource::GROUP_LIST_NEXT_OFFSET",
    "p/x (unsigned long)(static_cast<DoubleLinkedListElement<toit::Resource, 1>*>((toit::Resource*)0x1000)) - 0x1000",
  ],
  [
    "toit::ObjectNotifier::HEAP_LIST_ELEMENT_OFFSET",
    "p/x (unsigned long)(static_cast<DoubleLinkedListElement<toit::ObjectNotifier, 1>*>((toit::ObjectNotifier*)0x1000)) - 0x1000",
  ],
  [
    "toit::HeapRoot::HEAP_LIST_ELEMENT_OFFSET",
    "p/x (unsigned long)(static_cast<DoubleLinkedListElement<toit::HeapRoot, 1>*>((toit::HeapRoot*)0x1000)) - 0x1000",
  ],
  [
    "toit::FinalizerNode::HEAP_LIST_ELEMENT_OFFSET",
    "p/x (unsigned long)(static_cast<LinkedListElement<toit::FinalizerNode, 1>*>((toit::FinalizerNode*)0x1000)) - 0x1000",
  ],
]

OPTIONAL-CONSTANT-SPECS ::= [
  [
    "esp-idf::usb-serial-jtag-vfs::WRITE_LOCK_SLOT_ADDRESS",
    "p/x (unsigned long)&'usb_serial_jtag_vfs.c'::s_ctx.write_lock",
    "usb_serial_jtag_vfs.c",
    "s_ctx",
  ],
  [
    "esp-idf::gdma::PLATFORM_ADDRESS",
    "p/x (unsigned long)&'gdma.c'::s_platform",
    "gdma.c",
    "s_platform",
  ],
]

BT-RESERVED-REGION-CONSTANT-SPECS ::= [
  ["esp-idf::bt::reserved-region-0-start", "p/x (unsigned long)btdm_dram_available_region[0].start"],
  ["esp-idf::bt::reserved-region-0-end", "p/x (unsigned long)btdm_dram_available_region[0].end"],
  ["esp-idf::bt::reserved-region-1-start", "p/x (unsigned long)btdm_dram_available_region[1].start"],
  ["esp-idf::bt::reserved-region-1-end", "p/x (unsigned long)btdm_dram_available_region[1].end"],
  ["esp-idf::bt::reserved-region-2-start", "p/x (unsigned long)btdm_dram_available_region[2].start"],
  ["esp-idf::bt::reserved-region-2-end", "p/x (unsigned long)btdm_dram_available_region[2].end"],
  ["esp-idf::bt::reserved-region-3-start", "p/x (unsigned long)btdm_dram_available_region[3].start"],
  ["esp-idf::bt::reserved-region-3-end", "p/x (unsigned long)btdm_dram_available_region[3].end"],
  ["esp-idf::bt::reserved-region-4-start", "p/x (unsigned long)btdm_dram_available_region[4].start"],
  ["esp-idf::bt::reserved-region-4-end", "p/x (unsigned long)btdm_dram_available_region[4].end"],
  ["esp-idf::bt::reserved-region-5-start", "p/x (unsigned long)btdm_dram_available_region[5].start"],
  ["esp-idf::bt::reserved-region-5-end", "p/x (unsigned long)btdm_dram_available_region[5].end"],
  ["esp-idf::bt::reserved-region-6-start", "p/x (unsigned long)btdm_dram_available_region[6].start"],
  ["esp-idf::bt::reserved-region-6-end", "p/x (unsigned long)btdm_dram_available_region[6].end"],
]

main args/List:
  if args.size != 3:
    print "Usage: extract-runtime-layout GDB FIRMWARE.elf OUTPUT.json"
    throw "INVALID_ARGUMENTS"
  extract-runtime-layout args[0] args[1] args[2]

extract-runtime-layout gdb/string elf/string output/string -> none:
  layout := extract-runtime-layout-data gdb elf
  file.write-contents --path=output ((json.encode layout) + #[10])

/** Extracts the runtime layout from the exact firmware ELF. */
extract-runtime-layout-data gdb/string elf/string -> Map:
  type-specs := available-type-specs gdb elf
  symbol-names := available-symbol-names gdb elf
  constant-specs := available-constant-specs gdb elf
  commands := gdb-commands gdb elf type-specs symbol-names constant-specs
  commands.do: | command |
    if not command is string: throw "INVALID_GDB_COMMAND_ARGUMENT"
  gdb-output := run-gdb-batches commands
  layout/Map := parse-gdb-output
      gdb-output
      (fs.basename elf)
      type-specs
      symbol-names
      constant-specs
  dynamic-commands := dynamic-size-commands gdb elf layout["vtables"]
  dynamic-output := run-gdb-batches dynamic-commands
  add-dynamic-sizes layout (parse-gdb-values dynamic-output)
  return layout

run-gdb-batches commands/List -> string:
  prefix-size := 7
  batch-arguments := 80
  if commands.size < prefix-size: throw "INVALID_GDB_COMMANDS"
  prefix := commands[..prefix-size]
  result := ""
  offset := prefix-size
  while offset < commands.size:
    end := min commands.size (offset + batch-arguments)
    // Arguments after the common prefix are '-ex', command pairs.
    if ((end - offset) & 1) != 0: end--
    if end == offset: throw "INVALID_GDB_COMMANDS"
    result += pipe.backticks (prefix + commands[offset..end])
    offset = end
  return result

available-type-specs gdb/string elf/string -> List:
  result := []
  TYPE-SPECS.do: result.add it
  OPTIONAL-TYPE-SPECS.do: | spec/List |
    type-name/string := spec[0]
    if gdb-has-type gdb elf type-name: result.add spec
  return result

gdb-has-type gdb/string elf/string type-name/string -> bool:
  output := pipe.backticks [
    gdb,
    "-nx",
    "-q",
    "-batch",
    elf,
    "-ex",
    "info types ^$(type-name)",
  ]
  found := false
  normalized := output.replace --all "\r" ""
  normalized.split "\n": | raw/string |
    line := raw.trim
    if line.contains ":" and line.ends-with "$type-name;": found = true
  return found

available-symbol-names gdb/string elf/string -> List:
  result := []
  SYMBOL-NAMES.do: result.add it
  OPTIONAL-SYMBOL-NAMES.do: | name/string |
    if gdb-has-variable gdb elf name "": result.add name
  if gdb-has-symbol gdb elf "_bt_data_start":
    BT-SYMBOL-NAMES.do: result.add it
  return result

available-constant-specs gdb/string elf/string -> List:
  result := []
  CONSTANT-SPECS.do: result.add it
  OPTIONAL-CONSTANT-SPECS.do: | spec/List |
    source/string := spec[2]
    variable/string := spec[3]
    if gdb-has-variable gdb elf variable source:
      result.add spec[..2]
  if gdb-has-variable gdb elf "btdm_dram_available_region" "bt.c":
    BT-RESERVED-REGION-CONSTANT-SPECS.do: result.add it
  return result

gdb-has-variable
    gdb/string
    elf/string
    variable/string
    source/string
    -> bool:
  output := pipe.backticks [
    gdb,
    "-nx",
    "-q",
    "-batch",
    elf,
    "-ex",
    "info variables ^$(variable)",
  ]
  if source and not output.contains source: return false
  found := false
  normalized := output.replace --all "\r" ""
  normalized.split "\n": | raw/string |
    line := raw.trim
    if not line.starts-with "All variables" and
        line.contains ":" and
        line.contains variable:
      found = true
  return found

gdb-has-symbol gdb/string elf/string symbol/string -> bool:
  output := pipe.backticks [
    gdb,
    "-nx",
    "-q",
    "-batch",
    elf,
    "-ex",
    "info address $symbol",
  ]
  return output.contains "Symbol \"$symbol\" is"

gdb-commands
    gdb/string
    elf/string
    type-specs/List
    symbol-names/List
    constant-specs/List
    -> List:
  result := [gdb, "-nx", "-q", "-batch", elf, "-ex", "set language c++"]
  add-query result "POINTER" "p sizeof(void*)"
  type-index := 0
  type-specs.do: | spec/List |
    type-name/string := spec[0]
    add-query result "TYPE\t$type-index" "p sizeof($type-name)"
    fields/List := spec[1]
    field-index := 0
    fields.do: | field/string |
      add-query
          result
          "FIELD\t$type-index\t$field-index\tOFFSET"
          "p/x (unsigned long)&(($type-name*)0)->$field"
      add-query
          result
          "FIELD\t$type-index\t$field-index\tSIZE"
          "p sizeof((($type-name*)0)->$field)"
      field-index++
    type-index++
  symbol-index := 0
  symbol-names.do: | symbol/string |
    add-query
        result
        "SYMBOL\t$symbol-index"
        "p/x (unsigned long)&$symbol"
    symbol-index++
  constant-index := 0
  constant-specs.do: | spec/List |
    add-query result "CONSTANT\t$constant-index" spec[1]
    constant-index++
  result.add "-ex"
  result.add "info variables vtable for toit::"
  return result

dynamic-size-commands gdb/string elf/string vtables/List -> List:
  result := [gdb, "-nx", "-q", "-batch", elf, "-ex", "set language c++"]
  index := 0
  vtables.do: | entry/Map |
    name/string := entry["name"]
    if not name.contains "(anonymous namespace)":
      add-query result "DYNAMIC_TYPE\t$index" "p sizeof($name)"
    index++
  return result

add-query commands/List marker/string expression/string -> none:
  commands.add "-ex"
  commands.add "echo TOIT_INSPECTOR\t$marker\\n"
  commands.add "-ex"
  commands.add expression

parse-gdb-output
    output/string
    source/string
    type-specs/List
    symbol-names/List
    constant-specs/List
    -> Map:
  values := parse-gdb-values output
  normalized := output.replace --all "\r" ""

  pointer-size := required-natural values "POINTER"
  types := {:}
  type-index := 0
  type-specs.do: | spec/List |
    type-name/string := spec[0]
    fields := []
    field-names/List := spec[1]
    field-index := 0
    field-names.do: | field-name/string |
      fields.add {
        "name": field-name,
        "offset": required-natural
            values
            "FIELD\t$type-index\t$field-index\tOFFSET",
        "size": required-natural
            values
            "FIELD\t$type-index\t$field-index\tSIZE",
      }
      field-index++
    types[type-name] = {
      "name": type-name,
      "canonical-name": type-name,
      "size": required-natural values "TYPE\t$type-index",
      "fields": fields,
    }
    type-index++

  symbols := {:}
  OPTIONAL-SYMBOL-NAMES.do: | symbol/string |
    symbols[symbol] = {
      "name": symbol,
      "present": false,
    }
  symbol-index := 0
  symbol-names.do: | symbol/string |
    symbols[symbol] = {
      "name": symbol,
      "present": true,
      "address": hex-address (required-natural values "SYMBOL\t$symbol-index"),
    }
    symbol-index++
  constants := {:}
  constant-index := 0
  constant-specs.do: | spec/List |
    constants[spec[0]] = required-natural values "CONSTANT\t$constant-index"
    constant-index++
  vtables := parse-vtables normalized pointer-size
  return {
    "format": "toit-runtime-layout",
    "format-version": 1,
    "source": source,
    "pointer-size": pointer-size,
    "byte-order": "little",
    "types": types,
    "symbols": symbols,
    "constants": constants,
    "vtables": vtables,
  }

parse-gdb-values output/string -> Map:
  values := {:}
  active/string? := null
  normalized := output.replace --all "\r" ""
  normalized.split "\n": | raw/string |
    line := raw.trim
    if line.starts-with "TOIT_INSPECTOR\t":
      active = line[15..]
    else if active and line.starts-with "\$" and line.contains "=":
      equals := line.index-of "="
      values[active] = line[equals + 1..].trim
      active = null
  return values

add-dynamic-sizes layout/Map values/Map -> none:
  types/Map := layout["types"]
  vtables/List := layout["vtables"]
  index := 0
  vtables.do: | entry/Map |
    text/string? := values.get "DYNAMIC_TYPE\t$index"
    if text:
      size := parse-natural text
      entry["object-size"] = size
      name/string := entry["name"]
      if not types.contains name:
        types[name] = {
          "name": name,
          "canonical-name": name,
          "size": size,
          "fields": [],
          "dynamic-size-only": true,
        }
    index++

parse-vtables output/string pointer-size/int -> List:
  result := []
  seen := {}
  output.split "\n": | raw/string |
    line := raw.trim
    marker := "  vtable for "
    position := line.index-of marker
    if position <= 0: continue.split
    address-text := line[..position].trim
    if not address-text.starts-with "0x": continue.split
    address := int.parse --radix=16 address-text[2..]
    name := line[position + marker.size..].trim
    if name.is-empty or seen.contains address: continue.split
    seen.add address
    result.add {
      "name": name,
      "symbol-address": hex-address address,
      "address-point": hex-address (address + 2 * pointer-size),
    }
  return result

required-natural values/Map key/string -> int:
  text/string? := values.get key
  if not text: throw "GDB_LAYOUT_VALUE_MISSING: $key"
  return parse-natural text

parse-natural text/string -> int:
  return text.starts-with "0x"
      ? int.parse --radix=16 text[2..]
      : int.parse text

hex-address value/int -> string:
  return "0x$(value.to-string --radix=16)"
