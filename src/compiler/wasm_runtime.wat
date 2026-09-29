  ;; Copyright (C) 2026 Toit contributors.
  ;;
  ;; This library is free software; you can redistribute it and/or
  ;; modify it under the terms of the GNU Lesser General Public
  ;; License as published by the Free Software Foundation; version
  ;; 2.1 only.
  ;;
  ;; This library is distributed in the hope that it will be useful,
  ;; but WITHOUT ANY WARRANTY; without even the implied warranty of
  ;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  ;; Lesser General Public License for more details.
  ;;
  ;; The license can be found in the file `LICENSE` in the top level
  ;; directory of this repository.

  ;; The runtime of the WebAssembly GC backend (see wasm_backend.cc).
  ;;
  ;; The backend splices this file into the generated module. The types
  ;; ($Object, $String, ...), the class ids ($cid.<Class>), the tags, and
  ;; the entry points ($entry.<name>) are defined by the backend.
  ;;
  ;; Primitives are named '$prim.<module>.<name>'. They take and return
  ;; 'eqref's, and return a '$Failure' with the error if they fail. The
  ;; backend only calls the primitives that exist in this file.

  (import "toit" "write" (func $js.write (param i32 i32 i32)))
  (import "toit" "exit" (func $js.exit (param i32)))
  (import "toit" "now_us" (func $js.now_us (result f64)))
  (import "toit" "time_us" (func $js.time_us (result f64)))
  (import "toit" "random" (func $js.random (result i32)))
  (import "toit" "missing_primitive" (func $js.missing_primitive (param i32 i32)))
  (import "toit" "float_to_string" (func $js.float_to_string (param f64 i32) (result i32)))
  (import "toit" "string_to_float" (func $js.string_to_float (param i32 i32) (result f64)))
  (import "toit" "fmod" (func $js.fmod (param f64 f64) (result f64)))
  (import "toit" "round" (func $js.round (param f64) (result f64)))
  ;; Tasks and messages. 'yield' and 'transfer' suspend the WebAssembly stack
  ;; (JavaScript Promise Integration).
  (import "toit" "yield" (func $js.yield))
  (import "toit" "transfer" (func $js.transfer (param eqref i32) (result eqref)))
  (import "toit" "task_new" (func $js.task_new (param eqref eqref) (result i32)))
  (import "toit" "has_messages" (func $js.has_messages (result i32)))
  (import "toit" "receive_message" (func $js.receive_message (result eqref)))
  (import "toit" "process_send" (func $js.process_send (param i32 i32 eqref) (result i32)))
  (import "toit" "encode_error" (func $js.encode_error (param eqref eqref) (result eqref)))
  (import "toit" "main_arguments" (func $js.main_arguments (result eqref)))
  (import "toit" "math" (func $js.math (param i32 f64 f64) (result f64)))
  (import "toit" "parse_float" (func $js.parse_float (param i32 i32) (result f64 i32)))
  (import "toit" "get_env" (func $js.get_env (param i32) (result i32)))
  (import "toit" "time_info" (func $js.time_info (param f64 i32)))
  ;; Timers and resource notifications.
  (import "toit" "timer_create" (func $js.timer_create (result i32)))
  (import "toit" "timer_arm" (func $js.timer_arm (param i32 f64)))
  (import "toit" "timer_delete" (func $js.timer_delete (param i32)))
  (import "toit" "register_monitor_notifier" (func $js.register_monitor_notifier (param eqref i32)))
  (import "toit" "unregister_monitor_notifier" (func $js.unregister_monitor_notifier (param i32)))
  (import "toit" "read_state" (func $js.read_state (param i32) (result i32)))
  ;; Primitives that are implemented in JavaScript. They take checked
  ;; arguments and return the result or a '$Failure'.
  (import "toit" "tison_encode" (func $js.tison_encode (param eqref) (result eqref)))
  (import "toit" "tison_decode" (func $js.tison_decode (param eqref) (result eqref)))
  (import "toit" "base64_encode" (func $js.base64_encode (param eqref i32) (result eqref)))
  (import "toit" "base64_decode" (func $js.base64_decode (param eqref i32) (result eqref)))
  (import "toit" "js_eval" (func $js.js_eval (param eqref) (result eqref)))
  (import "toit" "js_call_start" (func $js.js_call_start (param eqref eqref) (result eqref)))
  (import "toit" "js_call_result" (func $js.js_call_result (param eqref) (result eqref)))

  ;; Scratch memory to exchange strings with JavaScript.
  (memory $memory (export "memory") 1)
;; @end-imports

  ;; -------------------------------------------------------------------------
  ;; Errors.

  (global $error_strings (mut (ref null $Values)) (ref.null $Values))

  ;; Returns the error string with the given name (see $error.* below).
  (func $error (param $index i32) (result eqref)
    global.get $error_strings
    local.get $index
    array.get $Values)

  (func $fail (param $index i32) (result (ref $Failure))
    local.get $index
    call $error
    struct.new $Failure)

  ;; The indexes into $error_strings.
  (global $ERR.WRONG_OBJECT_TYPE i32 (i32.const 0))
  (global $ERR.OUT_OF_BOUNDS i32 (i32.const 1))
  (global $ERR.OUT_OF_RANGE i32 (i32.const 2))
  (global $ERR.INVALID_ARGUMENT i32 (i32.const 3))
  (global $ERR.DIVISION_BY_ZERO i32 (i32.const 4))
  (global $ERR.UNIMPLEMENTED i32 (i32.const 5))
  (global $ERR.ILLEGAL_UTF_8 i32 (i32.const 6))
  (global $ERR.OUT_OF_MEMORY i32 (i32.const 7))
  (global $ERR.ERROR i32 (i32.const 8))
  (global $ERR.NEGATIVE_ARGUMENT i32 (i32.const 9))
  (global $ERR.WRONG_BYTES_TYPE i32 (i32.const 10))
  (data $error_names "WRONG_OBJECT_TYPE OUT_OF_BOUNDS OUT_OF_RANGE INVALID_ARGUMENT DIVISION_BY_ZERO UNIMPLEMENTED ILLEGAL_UTF_8 OUT_OF_MEMORY ERROR NEGATIVE_ARGUMENT WRONG_BYTES_TYPE ")

  (func $create_error_strings
    (local $names (ref $Bytes)) (local $start i32) (local $i i32) (local $count i32)
    (local $result (ref $Values))
    i32.const 0
    i32.const 162  ;; Length of $error_names.
    array.new_data $Bytes $error_names
    local.set $names
    i32.const 11
    array.new_default $Values
    local.set $result
    block $done
      loop $loop
        local.get $i
        local.get $names
        array.len
        i32.ge_u
        br_if $done
        local.get $names
        local.get $i
        array.get_u $Bytes
        i32.const 32
        i32.eq
        if
          local.get $result
          local.get $count
          local.get $names
          local.get $start
          local.get $i
          call $string_from_bytes
          array.set $Values
          local.get $count
          i32.const 1
          i32.add
          local.set $count
          local.get $i
          i32.const 1
          i32.add
          local.set $start
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $result
    global.set $error_strings)

  (func $unimplemented_error (result eqref)
    global.get $ERR.UNIMPLEMENTED
    call $error)

  ;; Called for primitives that the runtime doesn't implement. Returns the
  ;; error, so the primitive's failure code can run.
  (func $missing_primitive (param $name eqref) (result eqref)
    (local $bytes (ref $Bytes))
    local.get $name
    ref.cast (ref $String)
    struct.get $String $bytes
    local.tee $bytes
    i32.const 0
    local.get $bytes
    array.len
    i32.const 0
    call $copy_to_memory
    i32.const 0
    local.get $bytes
    array.len
    call $js.missing_primitive
    call $unimplemented_error)

  ;; -------------------------------------------------------------------------
  ;; Objects.

  (func $class_id (param $o eqref) (result i32)
    local.get $o
    ref.is_null
    if (result i32)
      global.get $cid.Null_
    else
      local.get $o
      ref.test (ref i31)
      if (result i32)
        global.get $cid.SmallInteger_
      else
        local.get $o
        ref.cast (ref $Object)
        struct.get $Object $cid
      end
    end)

  ;; Everything except null and false is true.
  (func $truthy (param $o eqref) (result i32)
    local.get $o
    ref.is_null
    if (result i32)
      i32.const 0
    else
      local.get $o
      global.get $false
      ref.eq
      i32.eqz
    end)

  (func $boolean (param $value i32) (result eqref)
    local.get $value
    if (result eqref)
      global.get $true
    else
      global.get $false
    end)

  ;; Returns the index of the method in the dispatch table for a virtual
  ;; call. Calls the lookup-failure entry point if the receiver doesn't have
  ;; a method for the selector.
  (func $dispatch_index (param $receiver eqref) (param $offset i32) (result i32)
    (local $index i32)
    local.get $receiver
    call $class_id
    local.get $offset
    i32.add
    local.tee $index
    global.get $selectors
    array.len
    i32.lt_u
    if
      global.get $selectors
      local.get $index
      array.get $I32s
      local.get $offset
      i32.eq
      if
        local.get $index
        return
      end
    end
    local.get $receiver
    local.get $offset
    ref.i31
    call $entry.lookup_failure
    drop
    unreachable)

  (func $is_class (param $o eqref) (param $start i32) (param $end i32) (param $nullable i32) (result i32)
    (local $id i32)
    local.get $nullable
    if
      local.get $o
      ref.is_null
      if
        i32.const 1
        return
      end
    end
    local.get $o
    call $class_id
    local.tee $id
    local.get $start
    i32.ge_s
    local.get $id
    local.get $end
    i32.lt_s
    i32.and)

  (func $is_interface (param $o eqref) (param $offset i32) (param $nullable i32) (result i32)
    (local $index i32)
    local.get $nullable
    if
      local.get $o
      ref.is_null
      if
        i32.const 1
        return
      end
    end
    local.get $o
    call $class_id
    local.get $offset
    i32.add
    local.tee $index
    global.get $selectors
    array.len
    i32.lt_u
    if (result i32)
      global.get $selectors
      local.get $index
      array.get $I32s
      local.get $offset
      i32.eq
    else
      i32.const 0
    end)

  ;; Floats are identical if they have the same bits, large integers and
  ;; strings if they have the same value.
  (func $identical (param $a eqref) (param $b eqref) (result i32)
    local.get $a
    local.get $b
    ref.eq
    if
      i32.const 1
      return
    end
    local.get $a
    ref.test (ref $Float)
    local.get $b
    ref.test (ref $Float)
    i32.and
    if
      local.get $a
      ref.cast (ref $Float)
      struct.get $Float $value
      i64.reinterpret_f64
      local.get $b
      ref.cast (ref $Float)
      struct.get $Float $value
      i64.reinterpret_f64
      i64.eq
      return
    end
    local.get $a
    ref.test (ref $LargeInt)
    local.get $b
    ref.test (ref $LargeInt)
    i32.and
    if
      local.get $a
      ref.cast (ref $LargeInt)
      struct.get $LargeInt $value
      local.get $b
      ref.cast (ref $LargeInt)
      struct.get $LargeInt $value
      i64.eq
      return
    end
    local.get $a
    ref.test (ref $String)
    local.get $b
    ref.test (ref $String)
    i32.and
    if
      local.get $a
      ref.cast (ref $String)
      struct.get $String $bytes
      local.get $b
      ref.cast (ref $String)
      struct.get $String $bytes
      call $bytes_equal
      return
    end
    i32.const 0)

  ;; The fast path of '=='. Returns 0 or 1 for the result, or 2 if the '=='
  ;; method must be called.
  (func $equals_fast (param $a eqref) (param $b eqref) (result i32)
    (local $compare i32)
    local.get $a
    local.get $b
    ref.eq
    if
      ;; All identical objects, except for NaNs, are equal to themselves.
      local.get $a
      ref.test (ref $Float)
      if
        local.get $a
        ref.cast (ref $Float)
        struct.get $Float $value
        local.get $a
        ref.cast (ref $Float)
        struct.get $Float $value
        f64.eq
        return
      end
      i32.const 1
      return
    end
    local.get $a
    ref.is_null
    local.get $b
    ref.is_null
    i32.or
    if
      i32.const 0
      return
    end
    local.get $a
    local.get $b
    call $compare_numbers
    local.tee $compare
    if
      local.get $compare
      i32.const 32  ;; COMPARE_FLAG_EQUAL.
      i32.and
      i32.const 0
      i32.ne
      return
    end
    i32.const 2)

  ;; -------------------------------------------------------------------------
  ;; Globals and literals.

  (func $load_global_lazy (param $id i32) (result eqref)
    (local $value eqref)
    global.get $globals
    local.get $id
    array.get $Values
    local.tee $value
    call $class_id
    global.get $cid.LazyInitializer_
    i32.eq
    if (result eqref)
      local.get $id
      ref.i31
      local.get $value
      call $entry.run_global_initializer
    else
      local.get $value
    end)

  ;; Creates the literals from the $strings data, as described by the
  ;; $literal_table: pairs of offset and length. Byte arrays are marked
  ;; with a negative length (-1 - length).
  (func $create_literals (param $count i32)
    (local $table (ref $I32s)) (local $i i32) (local $offset i32) (local $length i32)
    call $create_error_strings
    local.get $count
    array.new_default $Values
    global.set $literals
    i32.const 0
    local.get $count
    i32.const 2
    i32.mul
    array.new_data $I32s $literal_table
    local.set $table
    block $done
      loop $loop
        local.get $i
        local.get $count
        i32.ge_u
        br_if $done
        local.get $table
        local.get $i
        i32.const 2
        i32.mul
        array.get $I32s
        local.set $offset
        local.get $table
        local.get $i
        i32.const 2
        i32.mul
        i32.const 1
        i32.add
        array.get $I32s
        local.set $length
        global.get $literals
        local.get $i
        local.get $length
        i32.const 0
        i32.ge_s
        if (result eqref)
          local.get $offset
          local.get $length
          array.new_data $Bytes $strings
          call $new_string
        else
          global.get $cid.ByteArray_
          local.get $offset
          i32.const -1
          local.get $length
          i32.sub
          array.new_data $Bytes $strings
          struct.new $ByteArray
        end
        array.set $Values
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end)

  ;; -------------------------------------------------------------------------
  ;; Integers.

  ;; Integers that fit are small integers (i31). Others are boxed.
  (func $int (param $value i64) (result eqref)
    local.get $value
    i64.const 0x3fffffff
    i64.le_s
    local.get $value
    i64.const -0x40000000
    i64.ge_s
    i32.and
    if (result eqref)
      local.get $value
      i32.wrap_i64
      ref.i31
    else
      global.get $cid.LargeInteger_
      local.get $value
      struct.new $LargeInt
    end)

  (func $int32 (param $value i32) (result eqref)
    local.get $value
    i64.extend_i32_s
    call $int)

  (func $is_int (param $o eqref) (result i32)
    local.get $o
    ref.test (ref i31)
    local.get $o
    ref.test (ref $LargeInt)
    i32.or)

  ;; Returns the value of an integer. The caller must check that it is one.
  (func $int_value (param $o eqref) (result i64)
    local.get $o
    ref.test (ref i31)
    if (result i64)
      local.get $o
      ref.cast (ref i31)
      i31.get_s
      i64.extend_i32_s
    else
      local.get $o
      ref.cast (ref $LargeInt)
      struct.get $LargeInt $value
    end)

  (func $smi_value (param $o eqref) (result i32)
    local.get $o
    ref.cast (ref i31)
    i31.get_s)

  ;; Checks that the argument is a small integer, like the 'int' argument of
  ;; primitives. Returns the failure or null.
  (func $check_smi (param $o eqref) (result (ref null $Failure))
    local.get $o
    ref.test (ref i31)
    if
      ref.null $Failure
      return
    end
    local.get $o
    ref.test (ref $LargeInt)
    if (result (ref null $Failure))
      global.get $ERR.OUT_OF_RANGE
      call $fail
    else
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
    end)

  (func $float (param $value f64) (result (ref $Float))
    global.get $cid.float_
    local.get $value
    struct.new $Float)

  (func $float_value (param $o eqref) (result f64)
    local.get $o
    ref.cast (ref $Float)
    struct.get $Float $value)

  ;; Compares two numbers like Interpreter::compare_numbers. Returns 0
  ;; (COMPARE_FAILED) if they aren't both numbers.
  ;;
  ;; The results are combinations of the flags in interpreter.h:
  ;;   less:    MINUS_1 | STRICTLY_LESS | LESS_EQUAL | LESS_FOR_MIN = 1 | 8 | 16 | 4 = 29
  ;;   equal:   ZERO | LESS_EQUAL | EQUAL | GREATER_EQUAL = 2 | 16 | 32 | 64 = 114
  ;;   greater: PLUS_1 | STRICTLY_GREATER | GREATER_EQUAL = 3 | 128 | 64 = 195
  (func $compare_numbers (param $a eqref) (param $b eqref) (result i32)
    (local $x f64) (local $y f64) (local $a_is_int i32) (local $b_is_int i32)
    (local $the_int i64) (local $the_double f64)
    local.get $a
    call $is_int
    local.set $a_is_int
    local.get $b
    call $is_int
    local.set $b_is_int
    local.get $a_is_int
    local.get $b_is_int
    i32.and
    if
      local.get $a
      call $int_value
      local.get $b
      call $int_value
      call $compare_ints
      return
    end
    local.get $a_is_int
    if
      local.get $a
      call $int_value
      f64.convert_i64_s
      local.set $x
    else
      local.get $a
      ref.test (ref $Float)
      i32.eqz
      if
        i32.const 0
        return
      end
      local.get $a
      call $float_value
      local.set $x
    end
    local.get $b_is_int
    if
      local.get $b
      call $int_value
      f64.convert_i64_s
      local.set $y
    else
      local.get $b
      ref.test (ref $Float)
      i32.eqz
      if
        i32.const 0
        return
      end
      local.get $b
      call $float_value
      local.set $y
    end
    local.get $x
    local.get $y
    f64.lt
    if
      i32.const 29
      return
    end
    local.get $x
    local.get $y
    f64.gt
    if
      i32.const 195
      return
    end
    local.get $x
    local.get $y
    f64.ne
    if
      ;; NaNs are involved.
      local.get $x
      local.get $x
      f64.ne
      if
        local.get $y
        local.get $y
        f64.ne
        if
          i32.const 6  ;; ZERO | LESS_FOR_MIN.
          return
        end
        i32.const 7  ;; PLUS_1 | LESS_FOR_MIN.
        return
      end
      i32.const 1  ;; MINUS_1.
      return
    end
    ;; Equal. Special treatment for plus and minus zero.
    local.get $x
    f64.const 0
    f64.eq
    if
      local.get $x
      i64.reinterpret_f64
      i64.const 0
      i64.lt_s
      local.get $y
      i64.reinterpret_f64
      i64.const 0
      i64.lt_s
      i32.eq
      if
        i32.const 114
        return
      end
      local.get $x
      i64.reinterpret_f64
      i64.const 0
      i64.lt_s
      if
        i32.const 117  ;; MINUS_1 | LESS_EQUAL | EQUAL | GREATER_EQUAL | LESS_FOR_MIN.
        return
      end
      i32.const 115  ;; PLUS_1 | LESS_EQUAL | EQUAL | GREATER_EQUAL.
      return
    end
    local.get $a_is_int
    local.get $b_is_int
    i32.or
    i32.eqz
    if
      i32.const 114
      return
    end
    ;; One was an integer. They might only compare equal because of the
    ;; conversion to double.
    local.get $a_is_int
    if (result i64)
      local.get $a
      call $int_value
    else
      local.get $b
      call $int_value
    end
    local.tee $the_int
    i64.const -0x20000000000000
    i64.ge_s
    local.get $the_int
    i64.const 0x20000000000000
    i64.le_s
    i32.and
    if
      i32.const 114
      return
    end
    local.get $a_is_int
    if (result f64)
      local.get $y
    else
      local.get $x
    end
    local.tee $the_double
    f64.const -9223372036854778e3
    f64.le
    if
      i32.const 195
      i32.const 29
      local.get $a_is_int
      select
      return
    end
    local.get $the_double
    f64.const 9223372036854776e3
    f64.ge
    if
      i32.const 29
      i32.const 195
      local.get $a_is_int
      select
      return
    end
    local.get $a_is_int
    if (result i32)
      local.get $the_int
      local.get $the_double
      i64.trunc_f64_s
      call $compare_ints
    else
      local.get $the_double
      i64.trunc_f64_s
      local.get $the_int
      call $compare_ints
    end)

  (func $compare_ints (param $a i64) (param $b i64) (result i32)
    local.get $a
    local.get $b
    i64.lt_s
    if
      i32.const 29
      return
    end
    local.get $a
    local.get $b
    i64.eq
    if (result i32)
      i32.const 114
    else
      i32.const 195
    end)

  ;; -------------------------------------------------------------------------
  ;; Strings and blobs.

  (func $new_string (param $bytes (ref $Bytes)) (result (ref $String))
    global.get $cid.String_
    i32.const -1
    local.get $bytes
    struct.new $String)

  ;; Creates a string from a slice of bytes.
  (func $string_from_bytes (param $bytes (ref $Bytes)) (param $from i32) (param $to i32) (result (ref $String))
    (local $result (ref $Bytes))
    local.get $to
    local.get $from
    i32.sub
    array.new_default $Bytes
    local.tee $result
    i32.const 0
    local.get $bytes
    local.get $from
    local.get $to
    local.get $from
    i32.sub
    array.copy $Bytes $Bytes
    local.get $result
    call $new_string)

  (func $bytes_equal (param $a (ref $Bytes)) (param $b (ref $Bytes)) (result i32)
    local.get $a
    i32.const 0
    local.get $a
    array.len
    local.get $b
    i32.const 0
    local.get $b
    array.len
    call $blob_compare
    i32.eqz)

  ;; Compares the byte ranges lexicographically. Returns -1, 0, or 1.
  (func $blob_compare
      (param $a (ref $Bytes)) (param $a_from i32) (param $a_to i32)
      (param $b (ref $Bytes)) (param $b_from i32) (param $b_to i32)
      (result i32)
    (local $i i32) (local $x i32) (local $y i32) (local $length i32)
    local.get $a_to
    local.get $a_from
    i32.sub
    local.tee $length
    local.get $b_to
    local.get $b_from
    i32.sub
    local.tee $x
    local.get $length
    local.get $x
    i32.lt_s
    select
    local.set $length
    block $done
      loop $loop
        local.get $i
        local.get $length
        i32.ge_s
        br_if $done
        local.get $a
        local.get $a_from
        local.get $i
        i32.add
        array.get_u $Bytes
        local.set $x
        local.get $b
        local.get $b_from
        local.get $i
        i32.add
        array.get_u $Bytes
        local.set $y
        local.get $x
        local.get $y
        i32.ne
        if
          i32.const -1
          i32.const 1
          local.get $x
          local.get $y
          i32.lt_u
          select
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $a_to
    local.get $a_from
    i32.sub
    local.get $b_to
    local.get $b_from
    i32.sub
    i32.sub
    local.tee $x
    i32.eqz
    if (result i32)
      i32.const 0
    else
      i32.const -1
      i32.const 1
      local.get $x
      i32.const 0
      i32.lt_s
      select
    end)

  ;; The byte content of strings, byte arrays, and their slices, like
  ;; Object::byte_content. Returns the bytes and the range, or null bytes if
  ;; the object has no byte content. If $strings_only is set, byte arrays
  ;; are rejected.
  (func $blob (param $o eqref) (param $strings_only i32) (result (ref null $Bytes) i32 i32)
    (local $id i32) (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $wrapped_from i32) (local $wrapped_to i32) (local $f eqref) (local $t eqref)
    local.get $o
    ref.test (ref $String)
    if
      local.get $o
      ref.cast (ref $String)
      struct.get $String $bytes
      local.tee $bytes
      i32.const 0
      local.get $bytes
      array.len
      return
    end
    local.get $o
    ref.test (ref $ByteArray)
    if
      local.get $strings_only
      i32.eqz
      if
        local.get $o
        ref.cast (ref $ByteArray)
        struct.get $ByteArray $bytes
        local.tee $bytes
        i32.const 0
        local.get $bytes
        array.len
        return
      end
    end
    local.get $o
    call $class_id
    local.set $id
    local.get $strings_only
    i32.eqz
    local.get $id
    global.get $cid.CowByteArray_
    i32.eq
    i32.and
    if
      local.get $o
      call $field.CowByteArray_.0
      local.get $strings_only
      return_call $blob
    end
    local.get $strings_only
    i32.eqz
    local.get $id
    global.get $cid.ByteArraySlice_
    i32.eq
    i32.and
    local.get $id
    global.get $cid.StringSlice_
    i32.eq
    i32.or
    ;; Like the VM, string byte slices are accepted even if only strings are.
    local.get $id
    global.get $cid.StringByteSlice_
    i32.eq
    i32.or
    if
      ;; The slices all have the wrapped object, from, and to as their first
      ;; fields.
      local.get $id
      global.get $cid.ByteArraySlice_
      i32.eq
      if (result eqref)
        local.get $o
        call $field.ByteArraySlice_.1
        local.set $f
        local.get $o
        call $field.ByteArraySlice_.2
        local.set $t
        local.get $o
        call $field.ByteArraySlice_.0
      else
        local.get $id
        global.get $cid.StringSlice_
        i32.eq
        if (result eqref)
          local.get $o
          call $field.StringSlice_.1
          local.set $f
          local.get $o
          call $field.StringSlice_.2
          local.set $t
          local.get $o
          call $field.StringSlice_.0
        else
          local.get $o
          call $field.StringByteSlice_.1
          local.set $f
          local.get $o
          call $field.StringByteSlice_.2
          local.set $t
          local.get $o
          call $field.StringByteSlice_.0
        end
      end
      local.get $strings_only
      call $blob
      local.set $wrapped_to
      local.set $wrapped_from
      local.tee $bytes
      ref.is_null
      if
        ref.null $Bytes
        i32.const 0
        i32.const 0
        return
      end
      local.get $f
      ref.test (ref i31)
      local.get $t
      ref.test (ref i31)
      i32.and
      if
        local.get $f
        call $smi_value
        local.set $from
        local.get $t
        call $smi_value
        local.set $to
        local.get $from
        i32.const 0
        i32.ge_s
        local.get $from
        local.get $to
        i32.le_s
        i32.and
        local.get $to
        local.get $wrapped_to
        local.get $wrapped_from
        i32.sub
        i32.le_s
        i32.and
        if
          local.get $bytes
          local.get $wrapped_from
          local.get $from
          i32.add
          local.get $wrapped_from
          local.get $to
          i32.add
          return
        end
      end
    end
    ref.null $Bytes
    i32.const 0
    i32.const 0)

  ;; Returns the failure for a 'Blob' argument that isn't a blob, like the
  ;; VM's argument checking. The caller checks the other arguments.
  (func $blob_failure (result (ref $Failure))
    global.get $ERR.WRONG_BYTES_TYPE
    call $fail)

  ;; The hash code of a string, like String::compute_hash_code_for.
  (func $hash_bytes (param $bytes (ref $Bytes)) (param $from i32) (param $to i32) (result i32)
    (local $hash i32) (local $i i32)
    local.get $to
    local.get $from
    i32.sub
    local.set $hash
    local.get $from
    local.set $i
    block $done
      loop $loop
        local.get $i
        local.get $to
        i32.ge_s
        br_if $done
        local.get $hash
        i32.const 31
        i32.mul
        local.get $bytes
        local.get $i
        array.get_u $Bytes
        i32.add
        i32.const 0xffff
        i32.and
        local.set $hash
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $hash
    i32.const 0xffff
    i32.eq
    if (result i32)
      i32.const 0
    else
      local.get $hash
    end)

  ;; Copies bytes into the scratch memory at the given address.
  (func $copy_to_memory (param $bytes (ref $Bytes)) (param $from i32) (param $to i32) (param $address i32)
    block $done
      loop $loop
        local.get $from
        local.get $to
        i32.ge_s
        br_if $done
        local.get $address
        local.get $bytes
        local.get $from
        array.get_u $Bytes
        i32.store8
        local.get $address
        i32.const 1
        i32.add
        local.set $address
        local.get $from
        i32.const 1
        i32.add
        local.set $from
        br $loop
      end
    end)

  ;; Creates a string from bytes in the scratch memory.
  (func $string_from_memory (param $address i32) (param $length i32) (result (ref $String))
    (local $bytes (ref $Bytes)) (local $i i32)
    local.get $length
    array.new_default $Bytes
    local.set $bytes
    block $done
      loop $loop
        local.get $i
        local.get $length
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $i
        local.get $address
        local.get $i
        i32.add
        i32.load8_u
        array.set $Bytes
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $bytes
    call $new_string)

  ;; Writes bytes to stdout (1) or stderr (2), in chunks that fit into the
  ;; scratch memory.
  (func $write (param $fd i32) (param $bytes (ref $Bytes)) (param $from i32) (param $to i32)
    (local $chunk i32)
    block $done
      loop $loop
        local.get $from
        local.get $to
        i32.ge_s
        br_if $done
        local.get $to
        local.get $from
        i32.sub
        local.tee $chunk
        i32.const 65536
        i32.gt_s
        if
          i32.const 65536
          local.set $chunk
        end
        local.get $bytes
        local.get $from
        local.get $from
        local.get $chunk
        i32.add
        i32.const 0
        call $copy_to_memory
        local.get $fd
        i32.const 0
        local.get $chunk
        call $js.write
        local.get $from
        local.get $chunk
        i32.add
        local.set $from
        br $loop
      end
    end)

  ;; -------------------------------------------------------------------------
  ;; Tasks and process control.

  ;; Suspends the process until it has messages.
  (func $yield (result eqref)
    call $js.yield
    ref.null none)

  ;; Runs a new task. Called (through a promise-returning wrapper) by
  ;; JavaScript when a task is transferred to for the first time.
  (func (export "run_task") (param $task eqref) (param $lambda eqref)
    ;; The VM passes the task to '__entry__task' on the stack. The backend
    ;; makes '__entry__task' take it from Task_.current instead.
    global.get $globals
    global.get $gid.Task_.current
    local.get $task
    array.set $Values
    local.get $lambda
    call $entry.entry_task
    drop)

  (func $exit (param $code eqref)
    local.get $code
    ref.test (ref i31)
    if (result i32)
      local.get $code
      call $smi_value
    else
      i32.const 1
    end
    call $js.exit
    ;; Traps can't be caught, so no finally handlers run.
    unreachable)

  ;; -------------------------------------------------------------------------
  ;; Integer primitives. Small and large integers share the implementation:
  ;; the result is normalized by $int.

  (func $prim.core.smi_add (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.add
    call $int)

  (func $prim.core.smi_subtract (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.sub
    call $int)

  (func $prim.core.smi_multiply (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.mul
    call $int)

  (func $prim.core.smi_and (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.and
    call $int)

  (func $prim.core.smi_or (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.or
    call $int)

  (func $prim.core.smi_xor (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.xor
    call $int)

  (func $prim.core.smi_divide (param eqref eqref) (result eqref)
    (local $divisor i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $divisor
    i64.eqz
    if
      global.get $ERR.DIVISION_BY_ZERO
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get $divisor
    i64.div_s
    call $int)

  (func $prim.core.smi_mod (param eqref eqref) (result eqref)
    (local $divisor i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $divisor
    i64.eqz
    if
      global.get $ERR.DIVISION_BY_ZERO
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get $divisor
    i64.rem_s
    call $int)

  (func $prim.core.smi_less_than (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.lt_s
    call $boolean)

  (func $prim.core.smi_less_than_or_equal (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.le_s
    call $boolean)

  (func $prim.core.smi_greater_than (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.gt_s
    call $boolean)

  (func $prim.core.smi_greater_than_or_equal (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.ge_s
    call $boolean)

  (func $prim.core.smi_equals (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.eq
    call $boolean)

  (func $prim.core.smi_unary_minus (param eqref) (result eqref)
    local.get 0
    call $int_value
    i64.const -1
    i64.mul
    call $int)

  (func $prim.core.smi_not (param eqref) (result eqref)
    local.get 0
    call $int_value
    i64.const -1
    i64.xor
    call $int)

  (func $prim.core.smi_shift_left (param eqref eqref) (result eqref)
    (local $bits i64) (local $value i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $bits
    i64.const 0
    i64.lt_s
    if
      global.get $ERR.NEGATIVE_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.set $value
    local.get $bits
    i64.const 64
    i64.ge_s
    if
      i64.const 0
      call $int
      return
    end
    local.get $value
    local.get $bits
    i64.shl
    call $int)

  (func $prim.core.smi_shift_right (param eqref eqref) (result eqref)
    (local $bits i64) (local $value i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $bits
    i64.const 0
    i64.lt_s
    if
      global.get $ERR.NEGATIVE_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.set $value
    local.get $bits
    i64.const 64
    i64.ge_s
    if
      i64.const -1
      i64.const 0
      local.get $value
      i64.const 0
      i64.lt_s
      select
      call $int
      return
    end
    local.get $value
    local.get $bits
    i64.shr_s
    call $int)

  (func $prim.core.smi_unsigned_shift_right (param eqref eqref) (result eqref)
    (local $bits i64) (local $value i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $bits
    i64.const 0
    i64.lt_s
    if
      global.get $ERR.NEGATIVE_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.set $value
    local.get $bits
    i64.const 64
    i64.ge_s
    if
      i64.const 0
      call $int
      return
    end
    local.get $value
    local.get $bits
    i64.shr_u
    call $int)

  (func $prim.core.large_integer_add (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.add
    call $int)

  (func $prim.core.large_integer_subtract (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.sub
    call $int)

  (func $prim.core.large_integer_multiply (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.mul
    call $int)

  (func $prim.core.large_integer_and (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.and
    call $int)

  (func $prim.core.large_integer_or (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.or
    call $int)

  (func $prim.core.large_integer_xor (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.xor
    call $int)

  (func $prim.core.large_integer_divide (param eqref eqref) (result eqref)
    (local $divisor i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $divisor
    i64.eqz
    if
      global.get $ERR.DIVISION_BY_ZERO
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get $divisor
    i64.div_s
    call $int)

  (func $prim.core.large_integer_mod (param eqref eqref) (result eqref)
    (local $divisor i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $divisor
    i64.eqz
    if
      global.get $ERR.DIVISION_BY_ZERO
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get $divisor
    i64.rem_s
    call $int)

  (func $prim.core.large_integer_less_than (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.lt_s
    call $boolean)

  (func $prim.core.large_integer_less_than_or_equal (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.le_s
    call $boolean)

  (func $prim.core.large_integer_greater_than (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.gt_s
    call $boolean)

  (func $prim.core.large_integer_greater_than_or_equal (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.ge_s
    call $boolean)

  (func $prim.core.large_integer_equals (param eqref eqref) (result eqref)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.eq
    call $boolean)

  (func $prim.core.large_integer_unary_minus (param eqref) (result eqref)
    local.get 0
    call $int_value
    i64.const -1
    i64.mul
    call $int)

  (func $prim.core.large_integer_not (param eqref) (result eqref)
    local.get 0
    call $int_value
    i64.const -1
    i64.xor
    call $int)

  (func $prim.core.large_integer_shift_left (param eqref eqref) (result eqref)
    (local $bits i64) (local $value i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $bits
    i64.const 0
    i64.lt_s
    if
      global.get $ERR.NEGATIVE_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.set $value
    local.get $bits
    i64.const 64
    i64.ge_s
    if
      i64.const 0
      call $int
      return
    end
    local.get $value
    local.get $bits
    i64.shl
    call $int)

  (func $prim.core.large_integer_shift_right (param eqref eqref) (result eqref)
    (local $bits i64) (local $value i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $bits
    i64.const 0
    i64.lt_s
    if
      global.get $ERR.NEGATIVE_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.set $value
    local.get $bits
    i64.const 64
    i64.ge_s
    if
      i64.const -1
      i64.const 0
      local.get $value
      i64.const 0
      i64.lt_s
      select
      call $int
      return
    end
    local.get $value
    local.get $bits
    i64.shr_s
    call $int)

  (func $prim.core.large_integer_unsigned_shift_right (param eqref eqref) (result eqref)
    (local $bits i64) (local $value i64)
    local.get 1
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $int_value
    local.tee $bits
    i64.const 0
    i64.lt_s
    if
      global.get $ERR.NEGATIVE_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.set $value
    local.get $bits
    i64.const 64
    i64.ge_s
    if
      i64.const 0
      call $int
      return
    end
    local.get $value
    local.get $bits
    i64.shr_u
    call $int)

  ;; -------------------------------------------------------------------------
  ;; Float primitives.

  (func $prim.core.float_add (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.add
    call $float)

  (func $prim.core.float_subtract (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.sub
    call $float)

  (func $prim.core.float_multiply (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.mul
    call $float)

  (func $prim.core.float_divide (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.div
    call $float)

  (func $prim.core.float_mod (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    call $js.fmod
    call $float)

  (func $prim.core.float_less_than (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.lt
    call $boolean)

  (func $prim.core.float_less_than_or_equal (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.le
    call $boolean)

  (func $prim.core.float_greater_than (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.gt
    call $boolean)

  (func $prim.core.float_greater_than_or_equal (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.ge
    call $boolean)

  (func $prim.core.float_equals (param eqref eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 1
    call $float_value
    f64.eq
    call $boolean)

  (func $prim.core.float_unary_minus (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    f64.neg
    call $float)

  (func $prim.core.float_sqrt (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    f64.sqrt
    call $float)

  (func $prim.core.float_ceil (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    f64.ceil
    call $float)

  (func $prim.core.float_floor (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    f64.floor
    call $float)

  (func $prim.core.float_trunc (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    f64.trunc
    call $float)

  (func $prim.core.float_is_nan (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 0
    call $float_value
    f64.ne
    call $boolean)

  (func $prim.core.float_is_finite (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.get 0
    call $float_value
    f64.sub
    f64.const 0
    f64.eq
    call $boolean)

  (func $prim.core.float_to_raw (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    i64.reinterpret_f64
    call $int)

  (func $prim.core.float_to_raw32 (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    f32.demote_f64
    i32.reinterpret_f32
    i64.extend_i32_u
    call $int)

  ;; -------------------------------------------------------------------------
  ;; Core primitives.

  (func $prim.core.object_class_id (param eqref) (result eqref)
    local.get 0
    call $class_id
    ref.i31)

  (func $prim.core.write_on_stdout (param eqref eqref) (result eqref)
    i32.const 1
    local.get 0
    local.get 1
    call $write_on_std)

  (func $prim.core.write_on_stderr (param eqref eqref) (result eqref)
    i32.const 2
    local.get 0
    local.get 1
    call $write_on_std)

  (func $write_on_std (param $fd i32) (param $message eqref) (param $newline eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    local.get $message
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get $fd
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get $to
    call $write
    local.get $newline
    call $truthy
    if
      local.get $fd
      i32.const 10
      array.new_fixed $Bytes 1
      i32.const 0
      i32.const 1
      call $write
    end
    ref.null none)

  (func $prim.core.compare_to (param eqref eqref) (result eqref)
    (local $result i32)
    local.get 0
    local.get 1
    call $compare_numbers
    local.tee $result
    i32.eqz
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get $result
    i32.const 3  ;; COMPARE_RESULT_MASK.
    i32.and
    i32.const 2  ;; COMPARE_RESULT_BIAS is -2.
    i32.sub
    ref.i31)

  (func $prim.core.min_special_compare_to (param eqref eqref) (result eqref)
    (local $result i32)
    local.get 0
    local.get 1
    call $compare_numbers
    local.tee $result
    i32.eqz
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get $result
    i32.const 4  ;; COMPARE_FLAG_LESS_FOR_MIN.
    i32.and
    call $boolean)

  (func $prim.core.number_to_float (param eqref) (result eqref)
    local.get 0
    call $is_int
    if
      local.get 0
      call $int_value
      f64.convert_i64_s
      call $float
      return
    end
    local.get 0
    ref.test (ref $Float)
    if
      local.get 0
      return
    end
    global.get $ERR.WRONG_OBJECT_TYPE
    call $fail)

  (func $prim.core.number_to_integer (param eqref) (result eqref)
    (local $value f64)
    local.get 0
    call $is_int
    if
      local.get 0
      return
    end
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.tee $value
    local.get $value
    f64.ne
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get $value
    f64.const -9223372036854775808
    f64.lt
    local.get $value
    f64.const 9223372036854775807
    f64.ge
    i32.or
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $value
    i64.trunc_f64_s
    call $int)

  (func $prim.core.float_sign (param eqref) (result eqref)
    (local $value f64)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.tee $value
    local.get $value
    f64.ne
    if
      ;; All NaNs are treated as being positive.
      i32.const 1
      ref.i31
      return
    end
    local.get $value
    i64.reinterpret_f64
    i64.const 0
    i64.lt_s
    if
      i32.const -1
      ref.i31
      return
    end
    local.get $value
    f64.const 0
    f64.eq
    if (result eqref)
      i32.const 0
      ref.i31
    else
      i32.const 1
      ref.i31
    end)

  (func $prim.core.float_round (param eqref eqref) (result eqref)
    (local $value f64) (local $precision i32) (local $factor f64)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 1
    call $smi_value
    local.tee $precision
    i32.const 0
    i32.lt_s
    local.get $precision
    i32.const 15
    i32.gt_s
    i32.or
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $float_value
    local.tee $value
    local.get $value
    f64.ne
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $value
    f64.const 1e54
    f64.gt
    if
      local.get 0
      return
    end
    f64.const 1
    local.set $factor
    block $done
      loop $loop
        local.get $precision
        i32.eqz
        br_if $done
        local.get $factor
        f64.const 10
        f64.mul
        local.set $factor
        local.get $precision
        i32.const 1
        i32.sub
        local.set $precision
        br $loop
      end
    end
    local.get $value
    local.get $factor
    f64.mul
    call $js.round
    local.get $factor
    f64.div
    call $float)

  (func $prim.core.float_to_string (param eqref eqref) (result eqref)
    (local $precision i32)
    local.get 0
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const -1
    local.set $precision
    local.get 1
    ref.is_null
    i32.eqz
    if
      local.get 1
      ref.test (ref $LargeInt)
      if
        global.get $ERR.OUT_OF_BOUNDS
        call $fail
        return
      end
      local.get 1
      ref.test (ref i31)
      i32.eqz
      if
        global.get $ERR.WRONG_OBJECT_TYPE
        call $fail
        return
      end
      local.get 1
      call $smi_value
      local.tee $precision
      i32.const 0
      i32.lt_s
      local.get $precision
      i32.const 64
      i32.gt_s
      i32.or
      if
        global.get $ERR.OUT_OF_BOUNDS
        call $fail
        return
      end
    end
    i32.const 0
    local.get 0
    call $float_value
    local.get $precision
    call $js.float_to_string
    call $string_from_memory)

  (func $prim.core.smi_to_string_base_10 (param eqref) (result eqref)
    local.get 0
    call $int_value
    i32.const 10
    call $int_to_string)

  (func $prim.core.int64_to_string (param eqref eqref) (result eqref)
    (local $base i32)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 1
    call $smi_value
    local.tee $base
    i32.const 2
    i32.lt_s
    local.get $base
    i32.const 36
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get $base
    call $int_to_string)

  (func $prim.core.printf_style_int64_to_string (param eqref eqref) (result eqref)
    (local $base i32)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.tee $base
    i32.const 2
    i32.ne
    local.get $base
    i32.const 8
    i32.ne
    i32.and
    local.get $base
    i32.const 16
    i32.ne
    i32.and
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    ;; Printf style: negative numbers are printed as unsigned 64-bit.
    local.get 0
    call $int_value
    local.get $base
    call $uint_to_string)

  ;; Signed conversion for base 10 and negative numbers in other bases.
  ;; Non-negative numbers are the same in both conversions.
  (func $int_to_string (param $value i64) (param $base i32) (result eqref)
    local.get $value
    i64.const 0
    i64.lt_s
    if (result eqref)
      i64.const 0
      local.get $value
      i64.sub
      local.get $base
      i32.const 1
      call $digits_to_string
    else
      local.get $value
      local.get $base
      i32.const 0
      call $digits_to_string
    end)

  (func $uint_to_string (param $value i64) (param $base i32) (result eqref)
    local.get $value
    local.get $base
    i32.const 0
    call $digits_to_string)

  ;; Writes the (unsigned) value in the given base, with an optional minus
  ;; sign, into the scratch memory and returns it as a string.
  (func $digits_to_string (param $value i64) (param $base i32) (param $negative i32) (result eqref)
    (local $position i32) (local $digit i32) (local $base64 i64)
    i32.const 100
    local.set $position
    local.get $base
    i64.extend_i32_u
    local.set $base64
    loop $loop
      local.get $value
      local.get $base64
      i64.rem_u
      i32.wrap_i64
      local.set $digit
      local.get $position
      i32.const 1
      i32.sub
      local.tee $position
      local.get $digit
      i32.const 48  ;; '0'.
      i32.add
      local.get $digit
      i32.const 87  ;; 'a' - 10.
      i32.add
      local.get $digit
      i32.const 10
      i32.lt_u
      select
      i32.store8
      local.get $value
      local.get $base64
      i64.div_u
      local.tee $value
      i64.eqz
      i32.eqz
      br_if $loop
    end
    local.get $negative
    if
      local.get $position
      i32.const 1
      i32.sub
      local.tee $position
      i32.const 45  ;; '-'.
      i32.store8
    end
    local.get $position
    i32.const 100
    local.get $position
    i32.sub
    call $string_from_memory)

  (func $prim.core.count_leading_zeros (param eqref) (result eqref)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    i64.clz
    i32.wrap_i64
    ref.i31)

  (func $prim.core.popcount (param eqref) (result eqref)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    i64.popcnt
    i32.wrap_i64
    ref.i31)

  ;; The random number generator of the VM (see Process::random): xorshift128+,
  ;; seeded from JavaScript's random number generator unless the program
  ;; seeds it.
  (global $random_state0 (mut i64) (i64.const 1))
  (global $random_state1 (mut i64) (i64.const 2))
  (global $random_seeded (mut i32) (i32.const 0))

  (func $random (result i64)
    (local $s0 i64) (local $s1 i64)
    global.get $random_seeded
    i32.eqz
    if
      call $js.random
      i64.extend_i32_u
      call $js.random
      i64.extend_i32_u
      i64.const 32
      i64.shl
      i64.or
      global.set $random_state0
      call $js.random
      i64.extend_i32_u
      call $js.random
      i64.extend_i32_u
      i64.const 32
      i64.shl
      i64.or
      global.set $random_state1
      i32.const 1
      global.set $random_seeded
    end
    global.get $random_state0
    local.set $s1
    global.get $random_state1
    local.tee $s0
    global.set $random_state0
    local.get $s1
    local.get $s1
    i64.const 23
    i64.shl
    i64.xor
    local.tee $s1
    local.get $s1
    i64.const 18
    i64.shr_u
    i64.xor
    local.get $s0
    i64.xor
    local.get $s0
    i64.const 5
    i64.shr_u
    i64.xor
    global.set $random_state1
    global.get $random_state0
    global.get $random_state1
    i64.add)

  (func $prim.core.random (result eqref)
    call $random
    i32.wrap_i64
    i32.const 0xfffffff
    i32.and
    ref.i31)

  (func $prim.core.time (param eqref) (result eqref)
    local.get 0
    call $truthy
    if (result f64)
      call $js.now_us
    else
      call $js.time_us
    end
    i64.trunc_f64_s
    call $int)

  ;; The wall-clock time as [seconds, nanoseconds] since the epoch.
  (func $prim.core.get_real_time_clock (result eqref)
    (local $us i64) (local $seconds i64)
    call $js.time_us
    i64.trunc_f64_s
    local.tee $us
    i64.const 1000000
    i64.div_s
    local.set $seconds
    global.get $cid.SmallArray_
    local.get $seconds
    call $int
    local.get $us
    local.get $seconds
    i64.const 1000000
    i64.mul
    i64.sub
    i64.const 1000
    i64.mul
    call $int
    array.new_fixed $Values 2
    struct.new $Array)

  ;; Finalizers aren't supported yet. The objects are never finalized.
  (func $prim.core.add_finalizer (param eqref eqref) (result eqref)
    ref.null none)

  (func $prim.core.remove_finalizer (param eqref) (result eqref)
    global.get $false)

  (func $prim.core.process_current_id (result eqref)
    i32.const 0
    ref.i31)

  ;; -------------------------------------------------------------------------
  ;; Arrays.

  ;; The maximal size of arrays. Larger arrays are LargeArray_ objects that
  ;; are implemented in Toit. The VM limits arrays to 500 elements so they fit
  ;; in a heap page, but WebAssembly arrays don't have that limitation, and
  ;; plain arrays are much faster.
  (global $ARRAYLET_SIZE i32 (i32.const 0x4000000))

  (func $new_array (param $length i32) (param $filler eqref) (result (ref $Array))
    global.get $cid.SmallArray_
    local.get $filler
    local.get $length
    array.new $Values
    struct.new $Array)

  (func $prim.core.array_new (param eqref eqref) (result eqref)
    (local $length i32)
    block $ok
      local.get 0
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 0
    call $smi_value
    local.tee $length
    i32.const 0
    i32.lt_s
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $length
    global.get $ARRAYLET_SIZE
    i32.gt_s
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $length
    local.get 1
    call $new_array)

  (func $prim.core.array_length (param eqref) (result eqref)
    local.get 0
    ref.test (ref $Array)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $Array)
    struct.get $Array $values
    array.len
    ref.i31)

  (func $prim.core.array_at (param eqref eqref) (result eqref)
    (local $values (ref $Values)) (local $index i32)
    local.get 0
    ref.test (ref $Array)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 0
    ref.cast (ref $Array)
    struct.get $Array $values
    local.set $values
    local.get 1
    call $smi_value
    local.tee $index
    local.get $values
    array.len
    i32.ge_u
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $values
    local.get $index
    array.get $Values)

  (func $prim.core.array_at_put (param eqref eqref eqref) (result eqref)
    (local $values (ref $Values)) (local $index i32)
    local.get 0
    ref.test (ref $Array)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 0
    ref.cast (ref $Array)
    struct.get $Array $values
    local.set $values
    local.get 1
    call $smi_value
    local.tee $index
    local.get $values
    array.len
    i32.ge_u
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $values
    local.get $index
    local.get 2
    array.set $Values
    local.get 2)

  (func $prim.core.array_expand (param eqref eqref eqref eqref) (result eqref)
    (local $old (ref $Values)) (local $old_length i32) (local $length i32) (local $result (ref $Array))
    local.get 0
    ref.test (ref $Array)
    i32.eqz
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $Array)
    struct.get $Array $values
    local.set $old
    local.get 1
    call $smi_value
    local.set $old_length
    local.get 2
    call $smi_value
    local.tee $length
    i32.const 0
    i32.lt_s
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $length
    global.get $ARRAYLET_SIZE
    i32.gt_s
    local.get $old_length
    i32.const 0
    i32.lt_s
    i32.or
    local.get $old_length
    local.get $old
    array.len
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $length
    local.get 3
    call $new_array
    local.tee $result
    struct.get $Array $values
    i32.const 0
    local.get $old
    i32.const 0
    local.get $length
    local.get $old_length
    local.get $length
    local.get $old_length
    i32.lt_s
    select
    array.copy $Values $Values
    local.get $result)

  (func $prim.core.array_replace (param eqref eqref eqref eqref eqref) (result eqref)
    (local $dest (ref $Values)) (local $source (ref $Values))
    (local $index i32) (local $from i32) (local $to i32)
    local.get 0
    ref.test (ref $Array)
    local.get 2
    ref.test (ref $Array)
    i32.and
    local.get 1
    ref.test (ref i31)
    i32.and
    local.get 3
    ref.test (ref i31)
    i32.and
    local.get 4
    ref.test (ref i31)
    i32.and
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $Array)
    struct.get $Array $values
    local.set $dest
    local.get 2
    ref.cast (ref $Array)
    struct.get $Array $values
    local.set $source
    local.get 1
    call $smi_value
    local.set $index
    local.get 3
    call $smi_value
    local.set $from
    local.get 4
    call $smi_value
    local.set $to
    local.get $index
    i32.const 0
    i32.lt_s
    local.get $from
    i32.const 0
    i32.lt_s
    i32.or
    local.get $from
    local.get $to
    i32.gt_s
    i32.or
    local.get $to
    local.get $source
    array.len
    i32.gt_s
    i32.or
    local.get $index
    local.get $to
    i32.add
    local.get $from
    i32.sub
    local.get $dest
    array.len
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $dest
    local.get $index
    local.get $source
    local.get $from
    local.get $to
    local.get $from
    i32.sub
    array.copy $Values $Values
    ref.null none)

  ;; -------------------------------------------------------------------------
  ;; Byte arrays.

  (func $new_byte_array (param $bytes (ref $Bytes)) (result (ref $ByteArray))
    global.get $cid.ByteArray_
    local.get $bytes
    struct.new $ByteArray)

  ;; All byte arrays are on the WebAssembly heap.
  (func $prim.core.byte_array_new_external (param eqref) (result eqref)
    local.get 0
    i32.const 0
    ref.i31
    return_call $prim.core.byte_array_new)

  (func $prim.core.byte_array_new (param eqref eqref) (result eqref)
    (local $length i32)
    block $ok
      local.get 0
      call $check_smi
      br_on_null $ok
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 0
    call $smi_value
    local.tee $length
    i32.const 0
    i32.lt_s
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.get $length
    array.new $Bytes
    call $new_byte_array)

  (func $prim.core.byte_array_length (param eqref) (result eqref)
    local.get 0
    ref.test (ref $ByteArray)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $ByteArray)
    struct.get $ByteArray $bytes
    array.len
    ref.i31)

  (func $prim.core.byte_array_is_raw_bytes (param eqref) (result eqref)
    global.get $true)

  (func $prim.core.byte_array_at (param eqref eqref) (result eqref)
    (local $bytes (ref $Bytes)) (local $index i32)
    local.get 0
    ref.test (ref $ByteArray)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 0
    ref.cast (ref $ByteArray)
    struct.get $ByteArray $bytes
    local.set $bytes
    local.get 1
    call $smi_value
    local.tee $index
    local.get $bytes
    array.len
    i32.ge_u
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $bytes
    local.get $index
    array.get_u $Bytes
    ref.i31)

  (func $prim.core.byte_array_at_put (param eqref eqref eqref) (result eqref)
    (local $bytes (ref $Bytes)) (local $index i32) (local $value i32)
    local.get 0
    ref.test (ref $ByteArray)
    i32.eqz
    local.get 2
    call $is_int
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 0
    ref.cast (ref $ByteArray)
    struct.get $ByteArray $bytes
    local.set $bytes
    local.get 1
    call $smi_value
    local.tee $index
    local.get $bytes
    array.len
    i32.ge_u
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $bytes
    local.get $index
    local.get 2
    call $int_value
    i32.wrap_i64
    i32.const 0xff
    i32.and
    local.tee $value
    array.set $Bytes
    local.get $value
    ref.i31)

  ;; A mutable blob: byte arrays, and copy-on-write byte arrays and slices
  ;; that wrap them, like Object::mutable_byte_content. Returns null bytes if
  ;; the object isn't a mutable blob. Immutable copy-on-write byte arrays are
  ;; copied first.
  (func $mutable_blob (param $o eqref) (result (ref null $Bytes) i32 i32)
    (local $id i32) (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $copy (ref $Bytes)) (local $wrapped eqref) (local $f eqref) (local $t eqref)
    local.get $o
    ref.test (ref $ByteArray)
    if
      local.get $o
      i32.const 0
      call $blob
      return
    end
    local.get $o
    call $class_id
    local.tee $id
    global.get $cid.CowByteArray_
    i32.eq
    if
      local.get $o
      call $field.CowByteArray_.1
      global.get $true
      ref.eq
      if
        local.get $o
        call $field.CowByteArray_.0
        return_call $mutable_blob
      end
      ;; Copy the immutable backing.
      local.get $o
      call $field.CowByteArray_.0
      i32.const 0
      call $blob
      local.set $to
      local.set $from
      local.tee $bytes
      ref.is_null
      if
        ref.null $Bytes
        i32.const 0
        i32.const 0
        return
      end
      local.get $to
      local.get $from
      i32.sub
      array.new_default $Bytes
      local.tee $copy
      i32.const 0
      local.get $bytes
      ref.as_non_null
      local.get $from
      local.get $to
      local.get $from
      i32.sub
      array.copy $Bytes $Bytes
      local.get $o
      local.get $copy
      call $new_byte_array
      call $field_set.CowByteArray_.0
      local.get $o
      global.get $true
      call $field_set.CowByteArray_.1
      local.get $copy
      i32.const 0
      local.get $copy
      array.len
      return
    end
    local.get $id
    global.get $cid.ByteArraySlice_
    i32.eq
    if
      local.get $o
      call $field.ByteArraySlice_.0
      call $mutable_blob
      local.set $to
      local.set $from
      local.tee $bytes
      ref.is_null
      if
        ref.null $Bytes
        i32.const 0
        i32.const 0
        return
      end
      local.get $o
      call $field.ByteArraySlice_.1
      local.set $f
      local.get $o
      call $field.ByteArraySlice_.2
      local.set $t
      local.get $f
      ref.test (ref i31)
      local.get $t
      ref.test (ref i31)
      i32.and
      if
        local.get $f
        call $smi_value
        i32.const 0
        i32.ge_s
        local.get $f
        call $smi_value
        local.get $t
        call $smi_value
        i32.le_s
        i32.and
        local.get $t
        call $smi_value
        local.get $to
        local.get $from
        i32.sub
        i32.le_s
        i32.and
        if
          local.get $bytes
          local.get $from
          local.get $f
          call $smi_value
          i32.add
          local.get $from
          local.get $t
          call $smi_value
          i32.add
          return
        end
      end
    end
    ref.null $Bytes
    i32.const 0
    i32.const 0)

  (func $prim.core.byte_array_replace (param eqref eqref eqref eqref eqref) (result eqref)
    (local $dest (ref null $Bytes)) (local $dest_from i32) (local $dest_to i32)
    (local $source (ref null $Bytes)) (local $source_from i32) (local $source_to i32)
    (local $index i32) (local $from i32) (local $to i32)
    local.get 2
    i32.const 0
    call $blob
    local.set $source_to
    local.set $source_from
    local.tee $source
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get 0
    call $mutable_blob
    local.set $dest_to
    local.set $dest_from
    local.tee $dest
    ref.is_null
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 3
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 4
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.set $index
    local.get 3
    call $smi_value
    local.set $from
    local.get 4
    call $smi_value
    local.set $to
    local.get $index
    i32.const 0
    i32.lt_s
    local.get $from
    i32.const 0
    i32.lt_s
    i32.or
    local.get $to
    i32.const 0
    i32.lt_s
    i32.or
    local.get $to
    local.get $source_to
    local.get $source_from
    i32.sub
    i32.gt_s
    i32.or
    local.get $to
    local.get $from
    i32.lt_s
    i32.or
    local.get $index
    local.get $to
    i32.add
    local.get $from
    i32.sub
    local.get $dest_to
    local.get $dest_from
    i32.sub
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $dest
    ref.as_non_null
    local.get $dest_from
    local.get $index
    i32.add
    local.get $source
    ref.as_non_null
    local.get $source_from
    local.get $from
    i32.add
    local.get $to
    local.get $from
    i32.sub
    array.copy $Bytes $Bytes
    ref.null none)

  (func $prim.core.byte_array_convert_to_string (param eqref eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $start i32) (local $end i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    i32.const 0
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.set $start
    local.get 2
    call $smi_value
    local.set $end
    local.get $start
    i32.const 0
    i32.lt_s
    local.get $start
    local.get $end
    i32.gt_s
    i32.or
    local.get $end
    local.get $to
    local.get $from
    i32.sub
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get $start
    i32.add
    local.get $from
    local.get $end
    i32.add
    call $is_valid_utf_8
    i32.eqz
    if
      global.get $ERR.ILLEGAL_UTF_8
      call $fail
      return
    end
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get $start
    i32.add
    local.get $from
    local.get $end
    i32.add
    call $string_from_bytes)

  (func $prim.core.string_write_to_byte_array (param eqref eqref eqref eqref eqref) (result eqref)
    (local $source (ref null $Bytes)) (local $source_from i32) (local $source_to i32)
    (local $dest (ref null $Bytes)) (local $dest_from i32) (local $dest_to i32)
    (local $from i32) (local $to i32) (local $index i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $source_to
    local.set $source_from
    local.tee $source
    ref.is_null
    if
      call $blob_failure
      return
    end
    i32.const 0
    local.get 1
    call $mutable_blob
    local.set $dest_to
    local.set $dest_from
    local.tee $dest
    ref.is_null
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 3
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 4
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 2
    call $smi_value
    local.set $from
    local.get 3
    call $smi_value
    local.set $to
    local.get 4
    call $smi_value
    local.set $index
    local.get $to
    local.get $from
    i32.eq
    if
      local.get 1
      return
    end
    local.get $from
    i32.const 0
    i32.lt_s
    local.get $to
    local.get $source_to
    local.get $source_from
    i32.sub
    i32.gt_s
    i32.or
    local.get $from
    local.get $to
    i32.gt_s
    i32.or
    local.get $index
    local.get $to
    i32.add
    local.get $from
    i32.sub
    local.get $dest_to
    local.get $dest_from
    i32.sub
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $dest
    ref.as_non_null
    local.get $dest_from
    local.get $index
    i32.add
    local.get $source
    ref.as_non_null
    local.get $source_from
    local.get $from
    i32.add
    local.get $to
    local.get $from
    i32.sub
    array.copy $Bytes $Bytes
    local.get 1)

  ;; Checks that the bytes are valid UTF-8, like Utils::is_valid_utf_8:
  ;; no overlong sequences, no surrogates, and nothing above U+10FFFF.
  (func $is_valid_utf_8 (param $bytes (ref $Bytes)) (param $from i32) (param $to i32) (result i32)
    (local $c i32) (local $n i32) (local $value i32) (local $min i32) (local $i i32)
    block $done
      loop $loop
        local.get $from
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $from
        array.get_u $Bytes
        local.tee $c
        i32.const 0x80
        i32.lt_u
        if
          local.get $from
          i32.const 1
          i32.add
          local.set $from
          br $loop
        end
        ;; Determine the sequence length and the payload of the prefix.
        local.get $c
        i32.const 0xe0
        i32.and
        i32.const 0xc0
        i32.eq
        if
          i32.const 2
          local.set $n
          local.get $c
          i32.const 0x1f
          i32.and
          local.set $value
          i32.const 0x80
          local.set $min
        else
          local.get $c
          i32.const 0xf0
          i32.and
          i32.const 0xe0
          i32.eq
          if
            i32.const 3
            local.set $n
            local.get $c
            i32.const 0x0f
            i32.and
            local.set $value
            i32.const 0x800
            local.set $min
          else
            local.get $c
            i32.const 0xf8
            i32.and
            i32.const 0xf0
            i32.eq
            if
              i32.const 4
              local.set $n
              local.get $c
              i32.const 0x07
              i32.and
              local.set $value
              i32.const 0x10000
              local.set $min
            else
              i32.const 0
              return
            end
          end
        end
        local.get $from
        local.get $n
        i32.add
        local.get $to
        i32.gt_s
        if
          i32.const 0
          return
        end
        i32.const 1
        local.set $i
        block $bytes_done
          loop $bytes_loop
            local.get $i
            local.get $n
            i32.ge_s
            br_if $bytes_done
            local.get $bytes
            local.get $from
            local.get $i
            i32.add
            array.get_u $Bytes
            local.tee $c
            i32.const 0xc0
            i32.and
            i32.const 0x80
            i32.ne
            if
              i32.const 0
              return
            end
            local.get $value
            i32.const 6
            i32.shl
            local.get $c
            i32.const 0x3f
            i32.and
            i32.or
            local.set $value
            local.get $i
            i32.const 1
            i32.add
            local.set $i
            br $bytes_loop
          end
        end
        local.get $value
        local.get $min
        i32.lt_u
        local.get $value
        i32.const 0x10ffff
        i32.gt_u
        i32.or
        local.get $value
        i32.const 0xd800
        i32.ge_u
        local.get $value
        i32.const 0xdfff
        i32.le_u
        i32.and
        i32.or
        if
          i32.const 0
          return
        end
        local.get $from
        local.get $n
        i32.add
        local.set $from
        br $loop
      end
    end
    i32.const 1)

  ;; -------------------------------------------------------------------------
  ;; Strings.

  (func $prim.core.string_length (param eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    local.get 0
    i32.const 1
    call $blob
    local.set $to
    local.set $from
    ref.is_null
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $to
    local.get $from
    i32.sub
    ref.i31)

  (func $prim.core.string_raw_at (param eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $index i32)
    local.get 0
    i32.const 1
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 1
    call $smi_value
    local.tee $index
    local.get $to
    local.get $from
    i32.sub
    i32.ge_u
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $bytes
    local.get $from
    local.get $index
    i32.add
    array.get_u $Bytes
    ref.i31)

  (func $prim.core.string_at (param eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $index i32)
    (local $c i32) (local $n i32) (local $j i32)
    local.get 0
    i32.const 1
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    block $ok
      local.get 1
      call $check_smi
      br_on_null $ok
      return
    end
    local.get 1
    call $smi_value
    local.tee $index
    local.get $to
    local.get $from
    i32.sub
    i32.ge_u
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $bytes
    local.get $from
    local.get $index
    i32.add
    local.tee $index
    array.get_u $Bytes
    local.tee $c
    i32.const 0x80
    i32.lt_u
    if
      local.get $c
      ref.i31
      return
    end
    ;; Continuation bytes aren't the start of a character.
    local.get $c
    i32.const 0xc0
    i32.and
    i32.const 0x80
    i32.eq
    if
      ref.null none
      return
    end
    local.get $c
    i32.const 0xe0
    i32.and
    i32.const 0xc0
    i32.eq
    if
      i32.const 2
      local.set $n
      local.get $c
      i32.const 0x1f
      i32.and
      local.set $c
    else
      local.get $c
      i32.const 0xf0
      i32.and
      i32.const 0xe0
      i32.eq
      if
        i32.const 3
        local.set $n
        local.get $c
        i32.const 0x0f
        i32.and
        local.set $c
      else
        i32.const 4
        local.set $n
        local.get $c
        i32.const 0x07
        i32.and
        local.set $c
      end
    end
    i32.const 1
    local.set $j
    block $done
      loop $loop
        local.get $j
        local.get $n
        i32.ge_s
        br_if $done
        local.get $c
        i32.const 6
        i32.shl
        local.get $bytes
        local.get $index
        local.get $j
        i32.add
        array.get_u $Bytes
        i32.const 0x3f
        i32.and
        i32.or
        local.set $c
        local.get $j
        i32.const 1
        i32.add
        local.set $j
        br $loop
      end
    end
    local.get $c
    ref.i31)

  (func $prim.core.string_hash_code (param eqref) (result eqref)
    (local $string (ref $String)) (local $hash i32)
    local.get 0
    ref.test (ref $String)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $String)
    local.tee $string
    struct.get $String $hash
    local.tee $hash
    i32.const -1
    i32.eq
    if
      local.get $string
      local.get $string
      struct.get $String $bytes
      i32.const 0
      local.get $string
      struct.get $String $bytes
      array.len
      call $hash_bytes
      local.tee $hash
      struct.set $String $hash
    end
    local.get $hash
    ref.i31)

  (func $prim.core.blob_hash_code (param eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get $to
    call $hash_bytes
    ref.i31)

  (func $prim.core.blob_equals (param eqref eqref) (result eqref)
    (local $a (ref null $Bytes)) (local $a_from i32) (local $a_to i32)
    (local $b (ref null $Bytes)) (local $b_from i32) (local $b_to i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $a_to
    local.set $a_from
    local.tee $a
    ref.is_null
    local.get 1
    i32.const 0
    call $blob
    local.set $b_to
    local.set $b_from
    local.tee $b
    ref.is_null
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $a
    ref.as_non_null
    local.get $a_from
    local.get $a_to
    local.get $b
    ref.as_non_null
    local.get $b_from
    local.get $b_to
    call $blob_compare
    i32.eqz
    call $boolean)

  (func $prim.core.string_compare (param eqref eqref) (result eqref)
    (local $a (ref null $Bytes)) (local $a_from i32) (local $a_to i32)
    (local $b (ref null $Bytes)) (local $b_from i32) (local $b_to i32)
    local.get 0
    local.get 1
    ref.eq
    if
      i32.const 0
      ref.i31
      return
    end
    local.get 0
    i32.const 1
    call $blob
    local.set $a_to
    local.set $a_from
    local.tee $a
    ref.is_null
    local.get 1
    i32.const 1
    call $blob
    local.set $b_to
    local.set $b_from
    local.tee $b
    ref.is_null
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $a
    ref.as_non_null
    local.get $a_from
    local.get $a_to
    local.get $b
    ref.as_non_null
    local.get $b_from
    local.get $b_to
    call $blob_compare
    ref.i31)

  ;; Strings and string slices are known to contain valid UTF-8.
  (func $is_validated_string (param $o eqref) (result i32)
    local.get $o
    ref.test (ref $String)
    if
      i32.const 1
      return
    end
    local.get $o
    call $class_id
    global.get $cid.StringSlice_
    i32.eq)

  (func $prim.core.string_add (param eqref eqref) (result eqref)
    (local $a (ref null $Bytes)) (local $a_from i32) (local $a_to i32)
    (local $b (ref null $Bytes)) (local $b_from i32) (local $b_to i32)
    (local $result (ref $Bytes))
    local.get 0
    call $is_validated_string
    local.get 1
    call $is_validated_string
    i32.and
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    i32.const 1
    call $blob
    local.set $a_to
    local.set $a_from
    local.set $a
    local.get 1
    i32.const 1
    call $blob
    local.set $b_to
    local.set $b_from
    local.set $b
    local.get $a_to
    local.get $a_from
    i32.sub
    local.get $b_to
    local.get $b_from
    i32.sub
    i32.add
    array.new_default $Bytes
    local.tee $result
    i32.const 0
    local.get $a
    ref.as_non_null
    local.get $a_from
    local.get $a_to
    local.get $a_from
    i32.sub
    array.copy $Bytes $Bytes
    local.get $result
    local.get $a_to
    local.get $a_from
    i32.sub
    local.get $b
    ref.as_non_null
    local.get $b_from
    local.get $b_to
    local.get $b_from
    i32.sub
    array.copy $Bytes $Bytes
    local.get $result
    call $new_string)

  (func $prim.core.concat_strings (param eqref) (result eqref)
    (local $values (ref $Values)) (local $i i32) (local $length i32) (local $position i32)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $result (ref $Bytes))
    local.get 0
    ref.test (ref $Array)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $Array)
    struct.get $Array $values
    local.set $values
    ;; Compute the length, and check that all elements are strings.
    block $done
      loop $loop
        local.get $i
        local.get $values
        array.len
        i32.ge_u
        br_if $done
        local.get $values
        local.get $i
        array.get $Values
        call $is_validated_string
        i32.eqz
        if
          global.get $ERR.WRONG_OBJECT_TYPE
          call $fail
          return
        end
        local.get $values
        local.get $i
        array.get $Values
        i32.const 1
        call $blob
        local.set $to
        local.set $from
        drop
        local.get $length
        local.get $to
        local.get $from
        i32.sub
        i32.add
        local.set $length
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $length
    array.new_default $Bytes
    local.set $result
    i32.const 0
    local.set $i
    block $done
      loop $loop
        local.get $i
        local.get $values
        array.len
        i32.ge_u
        br_if $done
        local.get $values
        local.get $i
        array.get $Values
        i32.const 1
        call $blob
        local.set $to
        local.set $from
        local.set $bytes
        local.get $result
        local.get $position
        local.get $bytes
        ref.as_non_null
        local.get $from
        local.get $to
        local.get $from
        i32.sub
        array.copy $Bytes $Bytes
        local.get $position
        local.get $to
        local.get $from
        i32.sub
        i32.add
        local.set $position
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $result
    call $new_string)

  (func $prim.core.string_slice (param eqref eqref eqref) (result eqref)
    (local $bytes (ref $Bytes)) (local $length i32) (local $from i32) (local $to i32)
    local.get 0
    ref.test (ref $String)
    local.get 1
    ref.test (ref i31)
    i32.and
    local.get 2
    ref.test (ref i31)
    i32.and
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $String)
    struct.get $String $bytes
    local.tee $bytes
    array.len
    local.set $length
    local.get 1
    call $smi_value
    local.set $from
    local.get 2
    call $smi_value
    local.set $to
    local.get $from
    i32.eqz
    local.get $to
    local.get $length
    i32.eq
    i32.and
    if
      local.get 0
      return
    end
    local.get $from
    i32.const 0
    i32.lt_s
    local.get $to
    local.get $length
    i32.gt_s
    i32.or
    local.get $from
    local.get $to
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    ;; Don't cut UTF-8 sequences.
    local.get $from
    local.get $length
    i32.ne
    if
      local.get $bytes
      local.get $from
      array.get_u $Bytes
      i32.const 0xc0
      i32.and
      i32.const 0x80
      i32.eq
      if
        global.get $ERR.ILLEGAL_UTF_8
        call $fail
        return
      end
    end
    local.get $to
    local.get $length
    i32.ne
    if
      local.get $bytes
      local.get $to
      array.get_u $Bytes
      i32.const 0xc0
      i32.and
      i32.const 0x80
      i32.eq
      if
        global.get $ERR.ILLEGAL_UTF_8
        call $fail
        return
      end
    end
    local.get $bytes
    local.get $from
    local.get $to
    call $string_from_bytes)

  ;; -------------------------------------------------------------------------
  ;; Lists and maps.

  ;; Always use the Toit implementations.
  (func $prim.core.list_add (param eqref eqref) (result eqref)
    global.get $ERR.INVALID_ARGUMENT
    call $fail)

  (func $prim.core.rebuild_hash_index (param eqref eqref) (result eqref)
    global.get $ERR.OUT_OF_RANGE
    call $fail)

  ;; -------------------------------------------------------------------------
  ;; Tasks and messages.

  (global $next_task_id (mut i32) (i32.const 1))

  (func $prim.core.task_new (param eqref) (result eqref)
    (local $task eqref)
    call $new.Task_
    local.tee $task
    local.get $task
    local.get 0
    call $js.task_new
    ref.i31
    call $set.Task_.id
    local.get $task)

  ;; Transfers to another task. When the calling task is resumed, the
  ;; primitive fails with the task, so the failure code can make it the
  ;; current task.
  (func $prim.core.task_transfer (param eqref eqref) (result eqref)
    local.get 0
    local.get 1
    call $truthy
    call $js.transfer
    struct.new $Failure)

  (func $prim.core.main_arguments (result eqref)
    call $js.main_arguments)

  (func $prim.core.task_has_messages (result eqref)
    call $js.has_messages
    call $boolean)

  (func $prim.core.task_receive_message (result eqref)
    call $js.receive_message)

  (func $prim.core.process_send (param eqref eqref eqref) (result eqref)
    local.get 0
    ref.test (ref i31)
    local.get 1
    ref.test (ref i31)
    i32.and
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $smi_value
    local.get 1
    call $smi_value
    local.get 2
    call $js.process_send
    call $boolean)

  ;; Returns the error as a byte array. The VM encodes the error and the
  ;; stack trace for the system process, which decodes it with the source
  ;; map. Here, the JavaScript host remembers the stack trace for the byte
  ;; array, and prints it if the byte array is sent to the system process.
  (func $prim.core.encode_error (param eqref eqref) (result eqref)
    local.get 0
    local.get 1
    return_call $js.encode_error)

  ;; -------------------------------------------------------------------------
  ;; Timers and events. Resource groups and resources are small integers that
  ;; JavaScript uses as keys.

  (func $prim.timer.init (result eqref)
    i32.const 0
    ref.i31)

  (func $prim.timer.create (param eqref) (result eqref)
    call $js.timer_create
    ref.i31)

  (func $prim.timer.arm (param eqref eqref) (result eqref)
    local.get 0
    call $smi_value
    local.get 1
    call $int_value
    f64.convert_i64_s
    call $js.timer_arm
    ref.null none)

  (func $prim.timer.delete (param eqref eqref) (result eqref)
    local.get 1
    call $smi_value
    call $js.timer_delete
    ref.null none)

  (func $prim.events.register_monitor_notifier (param eqref eqref eqref) (result eqref)
    local.get 0
    local.get 2
    call $smi_value
    call $js.register_monitor_notifier
    ref.null none)

  (func $prim.events.unregister_monitor_notifier (param eqref eqref) (result eqref)
    local.get 1
    ref.test (ref i31)
    if
      local.get 1
      call $smi_value
      call $js.unregister_monitor_notifier
    end
    ref.null none)

  (func $prim.events.read_state (param eqref eqref) (result eqref)
    local.get 1
    call $smi_value
    call $js.read_state
    ref.i31)

  ;; -------------------------------------------------------------------------
  ;; Exports for JavaScript to convert between Toit and JavaScript values.

  ;; 0: null, 1: integer, 2: float, 3: string, 4: byte array, 5: array,
  ;; 6: true, 7: false, 8: other, 9: list.
  (func (export "value_kind") (param $o eqref) (result i32)
    (local $id i32)
    local.get $o
    ref.is_null
    if
      i32.const 0
      return
    end
    local.get $o
    call $is_int
    if
      i32.const 1
      return
    end
    local.get $o
    ref.test (ref $Float)
    if
      i32.const 2
      return
    end
    local.get $o
    ref.test (ref $String)
    if
      i32.const 3
      return
    end
    local.get $o
    ref.test (ref $ByteArray)
    if
      i32.const 4
      return
    end
    local.get $o
    ref.test (ref $Array)
    if
      i32.const 5
      return
    end
    local.get $o
    global.get $true
    ref.eq
    if
      i32.const 6
      return
    end
    local.get $o
    global.get $false
    ref.eq
    if
      i32.const 7
      return
    end
    local.get $o
    call $class_id
    local.tee $id
    global.get $cid.List_
    i32.eq
    if
      i32.const 9
      return
    end
    local.get $id
    global.get $cid.Map
    i32.eq
    if
      i32.const 10
      return
    end
    local.get $id
    global.get $cid.ListSlice_
    i32.eq
    if
      i32.const 11
      return
    end
    local.get $id
    global.get $cid.Tombstone_
    i32.eq
    if
      i32.const 12
      return
    end
    ;; String slices are strings, and the other byte containers are byte
    ;; arrays.
    local.get $id
    global.get $cid.StringSlice_
    i32.eq
    if
      i32.const 3
      return
    end
    local.get $id
    global.get $cid.CowByteArray_
    i32.eq
    local.get $id
    global.get $cid.ByteArraySlice_
    i32.eq
    i32.or
    local.get $id
    global.get $cid.StringByteSlice_
    i32.eq
    i32.or
    if
      i32.const 4
      return
    end
    i32.const 8)

  (func (export "class_id") (param $o eqref) (result i32)
    local.get $o
    call $class_id)

  (func (export "map_size") (param $o eqref) (result eqref)
    local.get $o
    call $get.Map.size)

  (func (export "map_backing") (param $o eqref) (result eqref)
    local.get $o
    call $get.Map.backing)

  ;; Creates a map with the given backing array of keys and values, like the
  ;; message decoder of the VM. The map builds its index when it is used.
  (func (export "new_map") (param $size i32) (param $backing eqref) (result eqref)
    (local $map (ref $Object))
    call $new.Map
    local.tee $map
    local.get $size
    ref.i31
    call $set.Map.size
    local.get $map
    i32.const 0
    ref.i31
    call $set.Map.spaces_left
    local.get $map
    local.get $backing
    call $set.Map.backing
    local.get $map)

  (func (export "list_slice_list") (param $o eqref) (result eqref)
    local.get $o
    call $get.ListSlice_.list)

  (func (export "list_slice_from") (param $o eqref) (result eqref)
    local.get $o
    call $get.ListSlice_.from)

  (func (export "list_slice_to") (param $o eqref) (result eqref)
    local.get $o
    call $get.ListSlice_.to)

  ;; Integers as 64-bit values (BigInts in JavaScript).
  (func (export "int64_value") (param $o eqref) (result i64)
    local.get $o
    call $int_value)

  (func (export "new_int64") (param $value i64) (result eqref)
    local.get $value
    call $int)

  ;; Primitive failures, for primitives that are implemented in JavaScript.
  (func (export "fail") (param $index i32) (result eqref)
    local.get $index
    call $fail)

  (func (export "failure") (param $value eqref) (result eqref)
    local.get $value
    struct.new $Failure)

  (func (export "list_array") (param $o eqref) (result eqref)
    local.get $o
    call $get.List_.array)

  (func (export "list_size") (param $o eqref) (result i32)
    local.get $o
    call $get.List_.size
    call $smi_value)

  (func (export "int_value") (param $o eqref) (result f64)
    local.get $o
    call $int_value
    f64.convert_i64_s)

  (func (export "float_value") (param $o eqref) (result f64)
    local.get $o
    call $float_value)

  ;; Copies the bytes of a string or byte array into the scratch memory at
  ;; address 0, growing the memory if necessary. Returns the length.
  (func (export "bytes_to_memory") (param $o eqref) (result i32)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $pages i32)
    local.get $o
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      i32.const -1
      return
    end
    local.get $to
    local.get $from
    i32.sub
    i32.const 65535
    i32.add
    i32.const 16
    i32.shr_u
    memory.size
    i32.sub
    local.tee $pages
    i32.const 0
    i32.gt_s
    if
      local.get $pages
      memory.grow
      drop
    end
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get $to
    i32.const 0
    call $copy_to_memory
    local.get $to
    local.get $from
    i32.sub)

  (func (export "array_length") (param $o eqref) (result i32)
    local.get $o
    ref.cast (ref $Array)
    struct.get $Array $values
    array.len)

  (func (export "array_get") (param $o eqref) (param $index i32) (result eqref)
    local.get $o
    ref.cast (ref $Array)
    struct.get $Array $values
    local.get $index
    array.get $Values)

  (func (export "new_array") (param $length i32) (result eqref)
    local.get $length
    ref.null none
    call $new_array)

  (func (export "array_set") (param $o eqref) (param $index i32) (param $value eqref)
    local.get $o
    ref.cast (ref $Array)
    struct.get $Array $values
    local.get $index
    local.get $value
    array.set $Values)

  ;; Creates a string from the bytes in the scratch memory.
  (func (export "new_string") (param $length i32) (result eqref)
    i32.const 0
    local.get $length
    call $string_from_memory)

  (func (export "new_byte_array") (param $length i32) (result eqref)
    i32.const 0
    local.get $length
    call $string_from_memory
    struct.get $String $bytes
    call $new_byte_array)

  (func (export "new_int") (param $value f64) (result eqref)
    local.get $value
    i64.trunc_sat_f64_s
    call $int)

  (func (export "new_float") (param $value f64) (result eqref)
    local.get $value
    call $float)

  (func (export "new_boolean") (param $value i32) (result eqref)
    local.get $value
    call $boolean)

  ;; Grows the scratch memory to hold at least the given number of bytes.
  (func (export "reserve_memory") (param $size i32)
    (local $pages i32)
    local.get $size
    i32.const 65535
    i32.add
    i32.const 16
    i32.shr_u
    memory.size
    i32.sub
    local.tee $pages
    i32.const 0
    i32.gt_s
    if
      local.get $pages
      memory.grow
      drop
    end)

  ;; -------------------------------------------------------------------------
  ;; Fast paths for the indexing operators and 'size', like the interpreter's
  ;; fast_at and fast_size. They return the result and 1, or 0 if the fast
  ;; path doesn't apply.

  ;; Returns the backing array and the size of a list, or null if the object
  ;; isn't a list with a small backing array.
  (func $list_backing (param $o eqref) (result (ref null $Values) i32)
    (local $array eqref)
    local.get $o
    call $class_id
    global.get $cid.List_
    i32.ne
    if
      ref.null $Values
      i32.const 0
      return
    end
    local.get $o
    call $get.List_.array
    local.tee $array
    ref.test (ref $Array)
    i32.eqz
    if
      ref.null $Values
      i32.const 0
      return
    end
    local.get $array
    ref.cast (ref $Array)
    struct.get $Array $values
    local.get $o
    call $get.List_.size
    call $smi_value)

  (func $fast_at (param $o eqref) (param $index eqref) (result eqref i32)
    (local $n i32) (local $values (ref null $Values)) (local $size i32) (local $bytes (ref $Bytes))
    local.get $index
    ref.test (ref i31)
    i32.eqz
    if
      ref.null none
      i32.const 0
      return
    end
    local.get $index
    call $smi_value
    local.set $n
    local.get $o
    ref.test (ref $Array)
    if
      local.get $o
      ref.cast (ref $Array)
      struct.get $Array $values
      local.tee $values
      array.len
      local.set $size
    else
      local.get $o
      ref.test (ref $ByteArray)
      if
        local.get $o
        ref.cast (ref $ByteArray)
        struct.get $ByteArray $bytes
        local.tee $bytes
        array.len
        local.get $n
        i32.gt_u
        if
          local.get $bytes
          local.get $n
          array.get_u $Bytes
          ref.i31
          i32.const 1
          return
        end
        ref.null none
        i32.const 0
        return
      end
      local.get $o
      call $list_backing
      local.set $size
      local.set $values
    end
    local.get $values
    ref.is_null
    local.get $n
    local.get $size
    i32.ge_u
    i32.or
    if
      ref.null none
      i32.const 0
      return
    end
    local.get $values
    local.get $n
    array.get $Values
    i32.const 1)

  (func $fast_at_put (param $o eqref) (param $index eqref) (param $value eqref) (result eqref i32)
    (local $n i32) (local $values (ref null $Values)) (local $size i32) (local $bytes (ref $Bytes))
    (local $byte i32)
    local.get $index
    ref.test (ref i31)
    i32.eqz
    if
      ref.null none
      i32.const 0
      return
    end
    local.get $index
    call $smi_value
    local.set $n
    local.get $o
    ref.test (ref $Array)
    if
      local.get $o
      ref.cast (ref $Array)
      struct.get $Array $values
      local.tee $values
      array.len
      local.set $size
    else
      local.get $o
      ref.test (ref $ByteArray)
      if
        local.get $value
        ref.test (ref i31)
        if
          local.get $o
          ref.cast (ref $ByteArray)
          struct.get $ByteArray $bytes
          local.tee $bytes
          array.len
          local.get $n
          i32.gt_u
          if
            local.get $bytes
            local.get $n
            local.get $value
            call $smi_value
            i32.const 0xff
            i32.and
            local.tee $byte
            array.set $Bytes
            local.get $byte
            ref.i31
            i32.const 1
            return
          end
        end
        ref.null none
        i32.const 0
        return
      end
      local.get $o
      call $list_backing
      local.set $size
      local.set $values
    end
    local.get $values
    ref.is_null
    local.get $n
    local.get $size
    i32.ge_u
    i32.or
    if
      ref.null none
      i32.const 0
      return
    end
    local.get $values
    local.get $n
    local.get $value
    array.set $Values
    local.get $value
    i32.const 1)

  (func $fast_size (param $o eqref) (result eqref i32)
    local.get $o
    ref.test (ref $Array)
    if
      local.get $o
      ref.cast (ref $Array)
      struct.get $Array $values
      array.len
      ref.i31
      i32.const 1
      return
    end
    local.get $o
    ref.test (ref $ByteArray)
    if
      local.get $o
      ref.cast (ref $ByteArray)
      struct.get $ByteArray $bytes
      array.len
      ref.i31
      i32.const 1
      return
    end
    local.get $o
    call $class_id
    global.get $cid.List_
    i32.eq
    if
      local.get $o
      call $get.List_.size
      i32.const 1
      return
    end
    ref.null none
    i32.const 0)

  ;; -------------------------------------------------------------------------
  ;; Math. The functions are computed by JavaScript's Math.

  (func $to_double (param $o eqref) (result f64 i32)
    local.get $o
    call $is_int
    if
      local.get $o
      call $int_value
      f64.convert_i64_s
      i32.const 1
      return
    end
    local.get $o
    ref.test (ref $Float)
    if
      local.get $o
      call $float_value
      i32.const 1
      return
    end
    f64.const 0
    i32.const 0)

  (func $prim.math.sin (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 0
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.cos (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 1
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.tan (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 2
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.sinh (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 3
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.cosh (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 4
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.tanh (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 5
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.asin (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 6
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.acos (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 7
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.atan (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 8
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.sqrt (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 9
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.exp (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 10
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.log (param eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 11
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.atan2 (param eqref eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $to_double
    local.set $ok
    local.set $y
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 12
    local.get $x
    local.get $y
    call $js.math
    call $float)

  (func $prim.math.pow (param eqref eqref) (result eqref)
    (local $x f64) (local $y f64) (local $ok i32)
    local.get 0
    call $to_double
    local.set $ok
    local.set $x
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $to_double
    local.set $ok
    local.set $y
    local.get $ok
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 13
    local.get $x
    local.get $y
    call $js.math
    call $float)

  ;; The order of the math operations for $js.math: sin, cos, tan, sinh, cosh, tanh, asin, acos, atan, sqrt, exp, log, atan2, pow

  ;; -------------------------------------------------------------------------
  ;; More core primitives.

  (data $platform_name "Wasm")
  (data $architecture_name "wasm-gc")

  (func $prim.core.platform (result eqref)
    i32.const 0
    i32.const 4
    array.new_data $Bytes $platform_name
    call $new_string)

  (func $prim.core.architecture (result eqref)
    i32.const 0
    i32.const 7
    array.new_data $Bytes $architecture_name
    call $new_string)

  (func $prim.core.get_generic_resource_group (result eqref)
    i32.const 0
    ref.i31)

  (func $prim.core.tune_memory_use (param eqref) (result eqref)
    ref.null none)

  (func $prim.core.gc_count (result eqref)
    i32.const 0
    ref.i31)

  ;; Seeds like Process::random_seed: the first 8 bytes (little endian) are
  ;; the first state, the next 8 the second.
  (func $prim.core.random_seed (param eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $i i32) (local $state0 i64) (local $state1 i64)
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    i64.const 0xdefa17
    local.set $state0
    i64.const 0xf00baa
    local.set $state1
    block $done
      loop $loop
        local.get $i
        i32.const 16
        i32.ge_s
        local.get $from
        local.get $i
        i32.add
        local.get $to
        i32.ge_s
        i32.or
        br_if $done
        local.get $i
        i32.const 8
        i32.lt_s
        if
          ;; Replace the i'th byte of the state.
          local.get $state0
          i64.const 0xff
          local.get $i
          i64.extend_i32_u
          i64.const 8
          i64.mul
          local.tee $state1
          i64.shl
          i64.const -1
          i64.xor
          i64.and
          local.get $bytes
          local.get $from
          local.get $i
          i32.add
          array.get_u $Bytes
          i64.extend_i32_u
          local.get $state1
          i64.shl
          i64.or
          local.set $state0
          ;; Restore the second state if we're still in the first half.
          i64.const 0xf00baa
          local.set $state1
        else
          local.get $state1
          i64.const 0xff
          local.get $i
          i32.const 8
          i32.sub
          i64.extend_i32_u
          i64.const 8
          i64.mul
          i64.shl
          i64.const -1
          i64.xor
          i64.and
          local.get $bytes
          local.get $from
          local.get $i
          i32.add
          array.get_u $Bytes
          i64.extend_i32_u
          local.get $i
          i32.const 8
          i32.sub
          i64.extend_i32_u
          i64.const 8
          i64.mul
          i64.shl
          i64.or
          local.set $state1
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $state0
    global.set $random_state0
    local.get $state1
    global.set $random_state1
    i32.const 1
    global.set $random_seeded
    ref.null none)

  ;; The WebAssembly GC doesn't give us any statistics.
  (func $prim.core.process_stats (param eqref eqref eqref eqref) (result eqref)
    (local $values (ref null $Values)) (local $size i32) (local $i i32)
    local.get 0
    ref.test (ref $Array)
    if
      local.get 0
      ref.cast (ref $Array)
      struct.get $Array $values
      local.tee $values
      array.len
      local.set $size
    else
      local.get 0
      call $list_backing
      local.set $size
      local.set $values
    end
    local.get $values
    ref.is_null
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    block $done
      loop $loop
        local.get $i
        local.get $size
        i32.ge_s
        br_if $done
        local.get $values
        local.get $i
        i32.const 0
        ref.i31
        array.set $Values
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get 0)

  (global $rtc_user_bytes (mut (ref null $ByteArray)) (ref.null $ByteArray))

  (func $prim.core.rtc_user_bytes (result eqref)
    global.get $rtc_user_bytes
    ref.is_null
    if
      i32.const 4096
      array.new_default $Bytes
      call $new_byte_array
      global.set $rtc_user_bytes
    end
    global.get $rtc_user_bytes)

  (func $prim.core.get_env (param eqref) (result eqref)
    (local $length i32)
    local.get 0
    ref.test (ref $String)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.cast (ref $String)
    struct.get $String $bytes
    i32.const 0
    local.get 0
    ref.cast (ref $String)
    struct.get $String $bytes
    array.len
    i32.const 0
    call $copy_to_memory
    local.get 0
    ref.cast (ref $String)
    struct.get $String $bytes
    array.len
    call $js.get_env
    local.tee $length
    i32.const 0
    i32.lt_s
    if
      ref.null none
      return
    end
    i32.const 0
    local.get $length
    call $string_from_memory)

  (func $prim.core.time_info (param eqref eqref) (result eqref)
    (local $result (ref $Array)) (local $i i32)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    f64.convert_i64_s
    local.get 1
    call $truthy
    call $js.time_info
    i32.const 9
    ref.null none
    call $new_array
    local.set $result
    ;; JavaScript wrote 9 i32 values into the scratch memory.
    block $done
      loop $loop
        local.get $i
        i32.const 9
        i32.ge_s
        br_if $done
        local.get $result
        struct.get $Array $values
        local.get $i
        local.get $i
        i32.const 4
        i32.mul
        i32.load
        ref.i31
        array.set $Values
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    ;; The last entry is the daylight saving time flag.
    local.get $result
    struct.get $Array $values
    i32.const 8
    i32.const 32
    i32.load
    call $boolean
    array.set $Values
    local.get $result)

  (func $prim.core.blob_index_of (param eqref eqref eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $start i32) (local $end i32)
    (local $byte i32) (local $from i32) (local $to i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $end
    local.set $start
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    i32.const 0
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 3
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.set $byte
    local.get 2
    call $smi_value
    local.set $from
    local.get 3
    call $smi_value
    local.set $to
    local.get $from
    i32.const 0
    i32.lt_s
    local.get $from
    local.get $to
    i32.gt_s
    i32.or
    local.get $to
    local.get $end
    local.get $start
    i32.sub
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    block $done
      loop $loop
        local.get $from
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $start
        local.get $from
        i32.add
        array.get_u $Bytes
        local.get $byte
        i32.eq
        if
          local.get $from
          ref.i31
          return
        end
        local.get $from
        i32.const 1
        i32.add
        local.set $from
        br $loop
      end
    end
    i32.const -1
    ref.i31)

  (func $prim.core.byte_array_is_valid_string_content (param eqref eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $start i32) (local $end i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    i32.const 0
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.set $start
    local.get 2
    call $smi_value
    local.set $end
    local.get $start
    i32.const 0
    i32.lt_s
    local.get $start
    local.get $end
    i32.gt_s
    i32.or
    local.get $end
    local.get $to
    local.get $from
    i32.sub
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get $start
    i32.add
    local.get $from
    local.get $end
    i32.add
    call $is_valid_utf_8
    call $boolean)

  ;; Counts the bytes that aren't UTF-8 continuation bytes.
  (func $prim.core.string_rune_count (param eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $count i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    block $done
      loop $loop
        local.get $from
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $from
        array.get_u $Bytes
        i32.const 0xc0
        i32.and
        i32.const 0x80
        i32.ne
        local.get $count
        i32.add
        local.set $count
        local.get $from
        i32.const 1
        i32.add
        local.set $from
        br $loop
      end
    end
    local.get $count
    ref.i31)

  ;; Parses a decimal integer with at most 18 characters. The Toit code
  ;; handles the difficult cases.
  (func $prim.core.int_parse (param eqref eqref eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $start i32) (local $end i32)
    (local $from i32) (local $to i32) (local $index i32) (local $c i32)
    (local $negative i32) (local $result i64)
    local.get 0
    i32.const 0
    call $blob
    local.set $end
    local.set $start
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    i32.const 0
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.set $from
    local.get 2
    call $smi_value
    local.set $to
    local.get $from
    i32.const 0
    i32.lt_s
    local.get $from
    local.get $to
    i32.ge_s
    i32.or
    local.get $to
    local.get $end
    local.get $start
    i32.sub
    i32.gt_s
    i32.or
    local.get $to
    local.get $from
    i32.sub
    i32.const 18
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $from
    local.set $index
    local.get $bytes
    local.get $start
    local.get $index
    i32.add
    array.get_u $Bytes
    i32.const 45  ;; '-'.
    i32.eq
    if
      i32.const 1
      local.set $negative
      local.get $index
      i32.const 1
      i32.add
      local.tee $index
      local.get $to
      i32.eq
      if
        global.get $ERR.INVALID_ARGUMENT
        call $fail
        return
      end
    end
    block $done
      loop $loop
        local.get $index
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $start
        local.get $index
        i32.add
        array.get_u $Bytes
        local.tee $c
        i32.const 48
        i32.sub
        i32.const 10
        i32.lt_u
        if
          local.get $result
          i64.const 10
          i64.mul
          local.get $c
          i32.const 48
          i32.sub
          i64.extend_i32_u
          i64.add
          local.set $result
        else
          local.get $c
          i32.const 95  ;; '_'.
          i32.eq
          if
            ;; Underscores can't be first or last.
            local.get $index
            local.get $from
            i32.eq
            local.get $index
            local.get $to
            i32.const 1
            i32.sub
            i32.eq
            i32.or
            local.get $negative
            local.get $index
            local.get $from
            i32.const 1
            i32.add
            i32.eq
            i32.and
            i32.or
            if
              global.get $ERR.INVALID_ARGUMENT
              call $fail
              return
            end
          else
            global.get $ERR.INVALID_ARGUMENT
            call $fail
            return
          end
        end
        local.get $index
        i32.const 1
        i32.add
        local.set $index
        br $loop
      end
    end
    local.get $negative
    if (result i64)
      i64.const 0
      local.get $result
      i64.sub
    else
      local.get $result
    end
    call $int)

  (func $prim.core.float_parse (param eqref eqref eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $start i32) (local $end i32)
    (local $from i32) (local $to i32) (local $value f64)
    local.get 0
    i32.const 0
    call $blob
    local.set $end
    local.set $start
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    i32.const 0
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get 2
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    call $smi_value
    local.set $from
    local.get 2
    call $smi_value
    local.set $to
    local.get $from
    i32.const 0
    i32.lt_s
    local.get $from
    local.get $to
    i32.ge_s
    i32.or
    local.get $to
    local.get $end
    local.get $start
    i32.sub
    i32.gt_s
    i32.or
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $bytes
    ref.as_non_null
    local.get $start
    local.get $from
    i32.add
    local.get $start
    local.get $to
    i32.add
    i32.const 0
    call $copy_to_memory
    ;; JavaScript parses like strtod. The second result tells whether the
    ;; whole input was a valid number.
    i32.const 0
    local.get $to
    local.get $from
    i32.sub
    call $js.parse_float
    local.set $from
    local.set $value
    local.get $from
    i32.eqz
    if
      global.get $ERR.ERROR
      call $fail
      return
    end
    local.get $value
    call $float)

  (func $prim.core.raw_to_float (param eqref) (result eqref)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    f64.reinterpret_i64
    call $float)

  (func $prim.core.raw32_to_float (param eqref) (result eqref)
    (local $raw i64)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.tee $raw
    i64.const 32
    i64.shr_u
    i64.eqz
    i32.eqz
    if
      global.get $ERR.OUT_OF_RANGE
      call $fail
      return
    end
    local.get $raw
    i32.wrap_i64
    f32.reinterpret_i32
    f64.promote_f32
    call $float)

  ;; -------------------------------------------------------------------------
  ;; Reading and writing integers in byte arrays.

  ;; Returns the bytes of a (mutable if requested) blob and checks that
  ;; 'offset' and 'offset + width' are within it. Returns null bytes on
  ;; failure, with the error index in the second result.
  (func $blob_range (param $o eqref) (param $mutable i32) (param $width i32) (param $offset eqref)
      (result (ref null $Bytes) i32)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $n i32)
    local.get $mutable
    if (result (ref null $Bytes) i32 i32)
      local.get $o
      call $mutable_blob
    else
      local.get $o
      i32.const 0
      call $blob
    end
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      ref.null $Bytes
      global.get $ERR.WRONG_OBJECT_TYPE
      global.get $ERR.WRONG_BYTES_TYPE
      local.get $mutable
      select
      return
    end
    local.get $offset
    ref.test (ref i31)
    i32.eqz
    if
      ref.null $Bytes
      global.get $ERR.WRONG_OBJECT_TYPE
      return
    end
    local.get $offset
    call $smi_value
    local.set $n
    ;; The offset is unsigned in the VM, so negative offsets are out of bounds.
    local.get $n
    i32.const 0
    i32.lt_s
    local.get $n
    local.get $width
    i32.add
    local.get $to
    local.get $from
    i32.sub
    i32.gt_s
    i32.or
    local.get $width
    i32.const 1
    i32.lt_s
    i32.or
    local.get $width
    i32.const 8
    i32.gt_s
    i32.or
    if
      ref.null $Bytes
      global.get $ERR.OUT_OF_BOUNDS
      return
    end
    local.get $bytes
    local.get $from
    local.get $n
    i32.add)

  ;; put-uint-{little,big}-endian unused dest width offset value.
  (func $put_uint (param $dest eqref) (param $width eqref) (param $offset eqref) (param $value eqref)
      (param $big_endian i32) (result eqref)
    (local $bytes (ref null $Bytes)) (local $start i32) (local $w i32) (local $v i64) (local $i i32)
    local.get $width
    ref.test (ref i31)
    local.get $value
    call $is_int
    i32.and
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $width
    call $smi_value
    local.set $w
    local.get $dest
    i32.const 1
    local.get $w
    local.get $offset
    call $blob_range
    local.set $start
    local.tee $bytes
    ref.is_null
    if
      local.get $start
      call $fail
      return
    end
    local.get $value
    call $int_value
    local.set $v
    block $done
      loop $loop
        local.get $i
        local.get $w
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $start
        local.get $big_endian
        if (result i32)
          local.get $w
          i32.const 1
          i32.sub
          local.get $i
          i32.sub
        else
          local.get $i
        end
        i32.add
        local.get $v
        i32.wrap_i64
        array.set $Bytes
        local.get $v
        i64.const 8
        i64.shr_u
        local.set $v
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    ref.null none)

  (func $prim.core.put_uint_little_endian (param eqref eqref eqref eqref eqref) (result eqref)
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    i32.const 0
    call $put_uint)

  (func $prim.core.put_uint_big_endian (param eqref eqref eqref eqref eqref) (result eqref)
    local.get 1
    local.get 2
    local.get 3
    local.get 4
    i32.const 1
    call $put_uint)

  ;; read-{int,uint}-{little,big}-endian unused source width offset.
  (func $read_int (param $source eqref) (param $width eqref) (param $offset eqref)
      (param $big_endian i32) (param $signed i32) (result eqref)
    (local $bytes (ref null $Bytes)) (local $start i32) (local $w i32) (local $v i64) (local $i i32)
    (local $byte i64)
    local.get $width
    ref.test (ref i31)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $width
    call $smi_value
    local.set $w
    local.get $source
    i32.const 0
    local.get $w
    local.get $offset
    call $blob_range
    local.set $start
    local.tee $bytes
    ref.is_null
    if
      local.get $start
      call $fail
      return
    end
    ;; Read the most significant byte first.
    block $done
      loop $loop
        local.get $i
        local.get $w
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $start
        local.get $big_endian
        if (result i32)
          local.get $i
        else
          local.get $w
          i32.const 1
          i32.sub
          local.get $i
          i32.sub
        end
        i32.add
        array.get_u $Bytes
        i64.extend_i32_u
        local.set $byte
        local.get $i
        i32.eqz
        local.get $signed
        i32.and
        if
          ;; Sign extend the most significant byte.
          local.get $byte
          i64.extend8_s
          local.set $byte
        end
        local.get $v
        i64.const 8
        i64.shl
        local.get $byte
        i64.or
        local.set $v
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $v
    call $int)

  (func $prim.core.read_int_little_endian (param eqref eqref eqref eqref) (result eqref)
    local.get 1
    local.get 2
    local.get 3
    i32.const 0
    i32.const 1
    call $read_int)

  (func $prim.core.read_int_big_endian (param eqref eqref eqref eqref) (result eqref)
    local.get 1
    local.get 2
    local.get 3
    i32.const 1
    i32.const 1
    call $read_int)

  (func $prim.core.read_uint_little_endian (param eqref eqref eqref eqref) (result eqref)
    local.get 1
    local.get 2
    local.get 3
    i32.const 0
    i32.const 0
    call $read_int)

  (func $prim.core.read_uint_big_endian (param eqref eqref eqref eqref) (result eqref)
    local.get 1
    local.get 2
    local.get 3
    i32.const 1
    i32.const 0
    call $read_int)

  (func $prim.core.put_float_64_little_endian (param eqref eqref eqref eqref) (result eqref)
    local.get 3
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    i32.const 8
    ref.i31
    local.get 2
    local.get 3
    call $float_value
    i64.reinterpret_f64
    call $int
    i32.const 0
    call $put_uint)

  (func $prim.core.put_float_32_little_endian (param eqref eqref eqref eqref) (result eqref)
    local.get 3
    ref.test (ref $Float)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 1
    i32.const 4
    ref.i31
    local.get 2
    local.get 3
    call $float_value
    f32.demote_f64
    i32.reinterpret_f32
    i64.extend_i32_u
    call $int
    i32.const 0
    call $put_uint)

  ;; -------------------------------------------------------------------------
  ;; Bitmaps.

  (func $prim.bitmap.byte_zap (param eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    local.get 0
    call $mutable_blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    local.get 1
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $bytes
    ref.as_non_null
    local.get $from
    local.get 1
    call $smi_value
    local.get $to
    local.get $from
    i32.sub
    array.fill $Bytes
    local.get $to
    local.get $from
    i32.sub
    ref.i31)

  ;; blit dest dest-pixel-stride dest-line-stride src src-pixel-stride
  ;;      src-line-stride pixels-per-line lut shift mask operation.
  ;; See primitive_bitmap.cc.
  (func $prim.bitmap.blit
      (param $dest_o eqref) (param $dps_o eqref) (param $dls_o eqref)
      (param $src_o eqref) (param $sps_o eqref) (param $sls_o eqref)
      (param $ppl_o eqref) (param $lut_o eqref) (param $shift_o eqref) (param $mask_o eqref)
      (param $op_o eqref) (result eqref)
    (local $dest (ref null $Bytes)) (local $dest_start i32) (local $dest_end i32)
    (local $src (ref null $Bytes)) (local $src_start i32) (local $src_end i32)
    (local $lut (ref null $Bytes)) (local $lut_start i32) (local $lut_end i32)
    (local $dps i32) (local $dls i32) (local $sps i32) (local $sls i32) (local $ppl i32)
    (local $shift i32) (local $mask i32) (local $op i32) (local $abs_dps i32)
    (local $src_offset i32) (local $dest_offset i32) (local $src_read_width i32) (local $dest_write_width i32)
    (local $src_index i32) (local $dest_index i32) (local $x i32) (local $pixel i32) (local $value i32)
    (local $dest_length i32) (local $src_length i32) (local $address i32)
    local.get $dest_o
    call $mutable_blob
    local.set $dest_end
    local.set $dest_start
    local.tee $dest
    ref.is_null
    local.get $src_o
    i32.const 0
    call $blob
    local.set $src_end
    local.set $src_start
    local.tee $src
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get $dps_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $dls_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $sps_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $sls_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $ppl_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $shift_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $mask_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    local.get $op_o
    ref.test (ref i31)
    i32.eqz
    i32.or
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get $dps_o
    call $smi_value
    local.set $dps
    local.get $dls_o
    call $smi_value
    local.set $dls
    local.get $sps_o
    call $smi_value
    local.set $sps
    local.get $sls_o
    call $smi_value
    local.set $sls
    local.get $ppl_o
    call $smi_value
    local.set $ppl
    local.get $shift_o
    call $smi_value
    local.set $shift
    local.get $mask_o
    call $smi_value
    local.set $mask
    local.get $op_o
    call $smi_value
    local.tee $op
    i32.const 0
    i32.lt_s
    local.get $op
    i32.const 6
    i32.ge_s
    i32.or
    if
      global.get $ERR.OUT_OF_BOUNDS
      call $fail
      return
    end
    ;; All values are limited to positive 23 bit values.
    local.get $dls
    local.get $sls
    i32.or
    local.get $ppl
    i32.or
    i32.const -0x800000
    i32.and
    local.get $sps
    i32.const -0x80
    i32.and
    i32.or
    local.get $dps
    i32.const -0x80
    i32.le_s
    i32.or
    local.get $dps
    i32.const 0x80
    i32.gt_s
    i32.or
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get $lut_o
    ref.is_null
    i32.eqz
    if
      local.get $lut_o
      i32.const 0
      call $blob
      local.set $lut_end
      local.set $lut_start
      local.tee $lut
      ref.is_null
      if
        global.get $ERR.WRONG_OBJECT_TYPE
        call $fail
        return
      end
      local.get $lut_end
      local.get $lut_start
      i32.sub
      i32.const 0x100
      i32.lt_s
      if
        global.get $ERR.INVALID_ARGUMENT
        call $fail
        return
      end
    end
    local.get $dps
    local.get $dps
    i32.const 31
    i32.shr_s
    local.tee $abs_dps
    i32.xor
    local.get $abs_dps
    i32.sub
    local.set $abs_dps
    local.get $dls
    i32.eqz
    local.get $sls
    i32.eqz
    i32.and
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get $ppl
    i32.const 1
    i32.sub
    local.tee $x
    local.get $sps
    i32.mul
    local.set $src_read_width
    local.get $x
    local.get $abs_dps
    i32.mul
    local.set $dest_write_width
    local.get $abs_dps
    local.get $dps
    i32.ne
    if
      local.get $op
      i32.const 3  ;; ADD_16_LE.
      i32.eq
      if
        global.get $ERR.INVALID_ARGUMENT
        call $fail
        return
      end
      local.get $dest_write_width
      local.set $dest_offset
      i32.const 0
      local.set $dest_write_width
    end
    local.get $op
    i32.const 3
    i32.eq
    if
      local.get $dest_write_width
      i32.const 1
      i32.add
      local.set $dest_write_width
    end
    local.get $dest_end
    local.get $dest_start
    i32.sub
    local.set $dest_length
    local.get $src_end
    local.get $src_start
    i32.sub
    local.set $src_length
    block $lines_done
      loop $lines
        local.get $src_offset
        local.get $src_read_width
        i32.add
        local.get $src_length
        i32.ge_s
        local.get $dest_offset
        local.get $dest_write_width
        i32.add
        local.get $dest_length
        i32.ge_s
        i32.or
        br_if $lines_done
        local.get $src_offset
        local.set $src_index
        local.get $dest_offset
        local.set $dest_index
        i32.const 0
        local.set $x
        block $pixels_done
          loop $pixels
            local.get $x
            local.get $ppl
            i32.ge_s
            br_if $pixels_done
            local.get $src
            local.get $src_start
            local.get $src_index
            i32.add
            array.get_u $Bytes
            local.set $pixel
            local.get $lut
            ref.is_null
            i32.eqz
            if
              local.get $lut
              local.get $lut_start
              local.get $pixel
              i32.add
              array.get_u $Bytes
              local.set $pixel
            end
            ;; Replicate into 16 bits, shift and mask.
            local.get $pixel
            local.get $pixel
            i32.const 8
            i32.shl
            i32.or
            i32.const 0xffff
            i32.and
            local.get $shift
            i32.const 7
            i32.and
            i32.shr_u
            local.get $mask
            i32.and
            i32.const 0xffff
            i32.and
            local.set $pixel
            local.get $dest_start
            local.get $dest_index
            i32.add
            local.set $address
            local.get $op
            i32.const 3
            i32.eq
            if
              ;; ADD_16_LE: saturating 16-bit little-endian add.
              local.get $dest
              local.get $address
              array.get_u $Bytes
              local.get $dest
              local.get $address
              i32.const 1
              i32.add
              array.get_u $Bytes
              i32.const 8
              i32.shl
              i32.or
              local.get $pixel
              i32.add
              local.tee $value
              i32.const 0xffff
              i32.gt_u
              if
                i32.const 0xffff
                local.set $value
              end
              local.get $dest
              local.get $address
              local.get $value
              array.set $Bytes
              local.get $dest
              local.get $address
              i32.const 1
              i32.add
              local.get $value
              i32.const 8
              i32.shr_u
              array.set $Bytes
            else
              local.get $dest
              local.get $address
              array.get_u $Bytes
              local.set $value
              local.get $op
              i32.eqz
              if
                local.get $pixel
                local.set $value
              end
              local.get $op
              i32.const 1
              i32.eq
              if
                local.get $value
                local.get $pixel
                i32.or
                local.set $value
              end
              local.get $op
              i32.const 2
              i32.eq
              if
                local.get $value
                local.get $pixel
                i32.const 0xff
                i32.and
                i32.add
                local.tee $value
                i32.const 0xff
                i32.gt_u
                if
                  i32.const 0xff
                  local.set $value
                end
              end
              local.get $op
              i32.const 4
              i32.eq
              if
                local.get $value
                local.get $pixel
                i32.and
                local.set $value
              end
              local.get $op
              i32.const 5
              i32.eq
              if
                local.get $value
                local.get $pixel
                i32.xor
                local.set $value
              end
              local.get $dest
              local.get $address
              local.get $value
              array.set $Bytes
            end
            local.get $x
            i32.const 1
            i32.add
            local.set $x
            local.get $src_index
            local.get $sps
            i32.add
            local.set $src_index
            local.get $dest_index
            local.get $dps
            i32.add
            local.set $dest_index
            br $pixels
          end
        end
        local.get $src_offset
        local.get $sls
        i32.add
        local.set $src_offset
        local.get $dest_offset
        local.get $dls
        i32.add
        local.set $dest_offset
        br $lines
      end
    end
    ref.null none)

  ;; -------------------------------------------------------------------------
  ;; Runes, UTF-16, and miscellaneous core primitives.

  (func $prim.core.uint64_to_string (param eqref) (result eqref)
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    i32.const 10
    call $uint_to_string)

  ;; Returns a bit mask with bit i set if byte i of the two integers is equal.
  (func $prim.core.int_vector_equals (param eqref eqref) (result eqref)
    (local $combined i64) (local $result i32) (local $i i32)
    local.get 0
    call $is_int
    local.get 1
    call $is_int
    i32.and
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    call $int_value
    local.get 1
    call $int_value
    i64.xor
    local.set $combined
    i32.const 0xff
    local.set $result
    block $done
      loop $loop
        local.get $combined
        i64.eqz
        br_if $done
        local.get $combined
        i64.const 0xff
        i64.and
        i64.eqz
        i32.eqz
        if
          local.get $result
          i32.const 1
          local.get $i
          i32.shl
          i32.const -1
          i32.xor
          i32.and
          local.set $result
        end
        local.get $combined
        i64.const 8
        i64.shr_u
        local.set $combined
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $result
    ref.i31)

  (func $prim.core.literal_index (param eqref) (result eqref)
    (local $i i32) (local $literals (ref $Values))
    local.get 0
    ref.is_null
    local.get 0
    ref.test (ref i31)
    i32.or
    if
      ref.null none
      return
    end
    global.get $literals
    ref.as_non_null
    local.set $literals
    block $done
      loop $loop
        local.get $i
        local.get $literals
        array.len
        i32.ge_u
        br_if $done
        local.get $literals
        local.get $i
        array.get $Values
        local.get 0
        ref.eq
        if
          local.get $i
          ref.i31
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    ref.null none)

  ;; The number of bytes of the UTF-8 encoding of a rune.
  (func $utf_8_length (param $rune i32) (result i32)
    local.get $rune
    i32.const 0x80
    i32.lt_u
    if
      i32.const 1
      return
    end
    local.get $rune
    i32.const 0x800
    i32.lt_u
    if
      i32.const 2
      return
    end
    i32.const 3
    i32.const 4
    local.get $rune
    i32.const 0x10000
    i32.lt_u
    select)

  ;; Writes the UTF-8 encoding of a rune at the given position. Returns the
  ;; position after it.
  (func $encode_utf_8 (param $bytes (ref $Bytes)) (param $position i32) (param $rune i32) (result i32)
    (local $length i32) (local $i i32)
    local.get $rune
    call $utf_8_length
    local.tee $length
    i32.const 1
    i32.eq
    if
      local.get $bytes
      local.get $position
      local.get $rune
      array.set $Bytes
      local.get $position
      i32.const 1
      i32.add
      return
    end
    ;; The continuation bytes, from the last one.
    local.get $length
    local.set $i
    loop $loop
      local.get $i
      i32.const 1
      i32.sub
      local.tee $i
      if
        local.get $bytes
        local.get $position
        local.get $i
        i32.add
        local.get $rune
        i32.const 0x3f
        i32.and
        i32.const 0x80
        i32.or
        array.set $Bytes
        local.get $rune
        i32.const 6
        i32.shr_u
        local.set $rune
        br $loop
      end
    end
    ;; The prefix: 0xc0, 0xe0, or 0xf0 for 2, 3, or 4 bytes.
    local.get $bytes
    local.get $position
    local.get $rune
    i32.const 0xff00
    local.get $length
    i32.shr_u
    i32.const 0xff
    i32.and
    i32.or
    array.set $Bytes
    local.get $position
    local.get $length
    i32.add)

  (func $prim.core.string_from_rune (param eqref) (result eqref)
    (local $rune i32) (local $bytes (ref $Bytes))
    local.get 0
    call $is_int
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    ref.test (ref i31)
    i32.eqz
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get 0
    call $smi_value
    local.tee $rune
    i32.const 0x10ffff
    i32.gt_u
    local.get $rune
    i32.const 0xd800
    i32.ge_u
    local.get $rune
    i32.const 0xdfff
    i32.le_u
    i32.and
    i32.or
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    local.get $rune
    call $utf_8_length
    array.new_default $Bytes
    local.tee $bytes
    i32.const 0
    local.get $rune
    call $encode_utf_8
    drop
    local.get $bytes
    call $new_string)

  ;; Decodes the UTF-16 code unit sequence starting at the given index of the
  ;; little-endian bytes. Unpaired surrogates become U+FFFD. Returns the rune
  ;; and the number of bytes consumed.
  (func $decode_utf_16 (param $bytes (ref $Bytes)) (param $index i32) (param $end i32) (result i32 i32)
    (local $c i32) (local $next i32)
    local.get $bytes
    local.get $index
    array.get_u $Bytes
    local.get $bytes
    local.get $index
    i32.const 1
    i32.add
    array.get_u $Bytes
    i32.const 8
    i32.shl
    i32.or
    local.tee $c
    i32.const 0xf800
    i32.and
    i32.const 0xd800
    i32.ne
    if
      local.get $c
      i32.const 2
      return
    end
    local.get $c
    i32.const 0xdc00
    i32.lt_u
    local.get $index
    i32.const 4
    i32.add
    local.get $end
    i32.le_u
    i32.and
    if
      local.get $bytes
      local.get $index
      i32.const 2
      i32.add
      array.get_u $Bytes
      local.get $bytes
      local.get $index
      i32.const 3
      i32.add
      array.get_u $Bytes
      i32.const 8
      i32.shl
      i32.or
      local.tee $next
      i32.const 0xfc00
      i32.and
      i32.const 0xdc00
      i32.eq
      if
        local.get $c
        i32.const 0x3ff
        i32.and
        i32.const 10
        i32.shl
        local.get $next
        i32.const 0x3ff
        i32.and
        i32.add
        i32.const 0x10000
        i32.add
        i32.const 4
        return
      end
    end
    i32.const 0xfffd
    i32.const 2)

  (func $prim.core.utf_16_to_string (param eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $index i32) (local $length i32) (local $rune i32) (local $consumed i32)
    (local $result (ref $Bytes)) (local $pass i32)
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get $to
    local.get $from
    i32.sub
    i32.const 1
    i32.and
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    ;; The first pass computes the length, the second one writes the bytes.
    i32.const 0
    array.new_default $Bytes
    local.set $result
    loop $passes
      local.get $from
      local.set $index
      i32.const 0
      local.set $length
      block $done
        loop $loop
          local.get $index
          local.get $to
          i32.ge_u
          br_if $done
          local.get $bytes
          ref.as_non_null
          local.get $index
          local.get $to
          call $decode_utf_16
          local.set $consumed
          local.set $rune
          local.get $pass
          if (result i32)
            local.get $result
            local.get $length
            local.get $rune
            call $encode_utf_8
          else
            local.get $length
            local.get $rune
            call $utf_8_length
            i32.add
          end
          local.set $length
          local.get $index
          local.get $consumed
          i32.add
          local.set $index
          br $loop
        end
      end
      local.get $pass
      i32.eqz
      if
        local.get $length
        array.new_default $Bytes
        local.set $result
        i32.const 1
        local.set $pass
        br $passes
      end
    end
    local.get $result
    call $new_string)

  (func $prim.core.string_to_utf_16 (param eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32)
    (local $index i32) (local $length i32) (local $c i32) (local $count i32)
    (local $result (ref $Bytes)) (local $pass i32) (local $unit i32)
    local.get 0
    i32.const 1
    call $blob
    local.set $to
    local.set $from
    local.tee $bytes
    ref.is_null
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    i32.const 0
    array.new_default $Bytes
    local.set $result
    loop $passes
      local.get $from
      local.set $index
      i32.const 0
      local.set $length
      block $done
        loop $loop
          local.get $index
          local.get $to
          i32.ge_u
          br_if $done
          ;; Decode the (valid) UTF-8 sequence.
          local.get $bytes
          ref.as_non_null
          local.get $index
          array.get_u $Bytes
          local.tee $c
          i32.const 0x80
          i32.lt_u
          if
            i32.const 1
            local.set $count
          else
            local.get $c
            i32.const 0xe0
            i32.lt_u
            if
              local.get $c
              i32.const 0x1f
              i32.and
              local.set $c
              i32.const 2
              local.set $count
            else
              local.get $c
              i32.const 0xf0
              i32.lt_u
              if
                local.get $c
                i32.const 0x0f
                i32.and
                local.set $c
                i32.const 3
                local.set $count
              else
                local.get $c
                i32.const 0x07
                i32.and
                local.set $c
                i32.const 4
                local.set $count
              end
            end
          end
          i32.const 1
          local.set $unit
          block $decoded
            loop $continuation
              local.get $unit
              local.get $count
              i32.ge_u
              br_if $decoded
              local.get $c
              i32.const 6
              i32.shl
              local.get $bytes
              ref.as_non_null
              local.get $index
              local.get $unit
              i32.add
              array.get_u $Bytes
              i32.const 0x3f
              i32.and
              i32.or
              local.set $c
              local.get $unit
              i32.const 1
              i32.add
              local.set $unit
              br $continuation
            end
          end
          local.get $index
          local.get $count
          i32.add
          local.set $index
          local.get $c
          i32.const 0x10000
          i32.ge_u
          if
            local.get $pass
            if
              local.get $c
              i32.const 0x10000
              i32.sub
              local.set $c
              local.get $result
              local.get $length
              local.get $c
              i32.const 10
              i32.shr_u
              i32.const 0xd800
              i32.add
              call $store_uint16
              local.get $result
              local.get $length
              i32.const 2
              i32.add
              local.get $c
              i32.const 0x3ff
              i32.and
              i32.const 0xdc00
              i32.add
              call $store_uint16
            end
            local.get $length
            i32.const 4
            i32.add
            local.set $length
          else
            local.get $pass
            if
              local.get $result
              local.get $length
              local.get $c
              call $store_uint16
            end
            local.get $length
            i32.const 2
            i32.add
            local.set $length
          end
          br $loop
        end
      end
      local.get $pass
      i32.eqz
      if
        local.get $length
        array.new_default $Bytes
        local.set $result
        i32.const 1
        local.set $pass
        br $passes
      end
    end
    local.get $result
    call $new_byte_array)

  (func $store_uint16 (param $bytes (ref $Bytes)) (param $index i32) (param $value i32)
    local.get $bytes
    local.get $index
    local.get $value
    array.set $Bytes
    local.get $bytes
    local.get $index
    i32.const 1
    i32.add
    local.get $value
    i32.const 8
    i32.shr_u
    array.set $Bytes)

  ;; -------------------------------------------------------------------------
  ;; Helpers for the JSON decoder (lib/encoding/json.toit).

  ;; Checks the (blob, offset) arguments of the JSON primitives. Returns the
  ;; failure or null.
  (func $json_check (param $o eqref) (param $offset eqref) (result eqref)
    local.get $o
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    if
      call $blob_failure
      return
    end
    block $ok
      local.get $offset
      call $check_smi
      br_on_null $ok
      return
    end
    local.get $offset
    call $smi_value
    i32.const 0
    i32.lt_s
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    ref.null none)

  (func $prim.core.json_skip_whitespace (param eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $i i32) (local $c i32)
    local.get 0
    local.get 1
    call $json_check
    br_on_non_null 0
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.set $bytes
    local.get $from
    local.get 1
    call $smi_value
    i32.add
    local.set $i
    block $done
      loop $loop
        local.get $i
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $i
        array.get_u $Bytes
        local.tee $c
        i32.const 32  ;; ' '.
        i32.ne
        local.get $c
        i32.const 10  ;; '\n'.
        i32.ne
        i32.and
        local.get $c
        i32.const 9  ;; '\t'.
        i32.ne
        i32.and
        local.get $c
        i32.const 13  ;; '\r'.
        i32.ne
        i32.and
        br_if $done
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $i
    local.get $from
    i32.sub
    ref.i31)

  ;; Returns the hash of the string that starts at the offset and ends at the
  ;; next double quote, or -1 if there is a backslash before it.
  (func $prim.core.hash_simple_json_string (param eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $start i32)
    (local $i i32) (local $c i32)
    local.get 0
    local.get 1
    call $json_check
    br_on_non_null 0
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.set $bytes
    local.get $from
    local.get 1
    call $smi_value
    i32.add
    local.tee $start
    local.set $i
    block $done
      loop $loop
        local.get $i
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $i
        array.get_u $Bytes
        local.tee $c
        i32.const 92  ;; '\\'.
        i32.eq
        br_if $done
        local.get $c
        i32.const 34  ;; '"'.
        i32.eq
        if
          local.get $bytes
          ref.as_non_null
          local.get $start
          local.get $i
          call $hash_bytes
          ref.i31
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    i32.const -1
    ref.i31)

  ;; Compares the string with the bytes at the offset, which must be followed
  ;; by a double quote.
  (func $prim.core.compare_simple_json_string (param eqref eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $start i32)
    (local $string (ref null $Bytes)) (local $string_from i32) (local $string_to i32)
    (local $length i32) (local $i i32)
    local.get 0
    local.get 1
    call $json_check
    br_on_non_null 0
    local.get 2
    i32.const 1
    call $blob
    local.set $string_to
    local.set $string_from
    local.tee $string
    ref.is_null
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.set $bytes
    local.get $from
    local.get 1
    call $smi_value
    i32.add
    local.set $start
    local.get $string_to
    local.get $string_from
    i32.sub
    local.tee $length
    local.get $to
    local.get $start
    i32.sub
    i32.ge_s
    if
      global.get $false
      return
    end
    ;; The first double quote must be right after the string.
    local.get $bytes
    local.get $start
    local.get $length
    i32.add
    array.get_u $Bytes
    i32.const 34  ;; '"'.
    i32.ne
    if
      global.get $false
      return
    end
    block $done
      loop $loop
        local.get $i
        local.get $length
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $start
        local.get $i
        i32.add
        array.get_u $Bytes
        local.get $string
        local.get $string_from
        local.get $i
        i32.add
        array.get_u $Bytes
        i32.ne
        if
          global.get $false
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    global.get $true)

  ;; Returns the size of the JSON number at the offset. The size is negative
  ;; if the number is a float.
  (func $prim.core.size_of_json_number (param eqref eqref) (result eqref)
    (local $bytes (ref null $Bytes)) (local $from i32) (local $to i32) (local $i i32)
    (local $c i32) (local $is_float i32)
    local.get 0
    local.get 1
    call $json_check
    br_on_non_null 0
    local.get 0
    i32.const 0
    call $blob
    local.set $to
    local.set $from
    local.set $bytes
    local.get $from
    local.get 1
    call $smi_value
    i32.add
    local.tee $i
    local.get $to
    i32.const 1
    i32.sub
    i32.ge_s
    if
      global.get $ERR.INVALID_ARGUMENT
      call $fail
      return
    end
    block $done
      loop $loop
        local.get $i
        local.get $to
        i32.ge_s
        br_if $done
        local.get $bytes
        local.get $i
        array.get_u $Bytes
        local.set $c
        ;; See the VM's primitive for the tables.
        i32.const 0x3ff6820
        local.get $c
        i32.shr_u
        i32.const 1
        i32.and
        i32.eqz
        local.get $c
        i32.const 13  ;; '\r'.
        i32.eq
        i32.or
        br_if $done
        i32.const 0x4020
        local.get $c
        i32.shr_u
        i32.const 1
        i32.and
        local.get $is_float
        i32.or
        local.set $is_float
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $loop
      end
    end
    local.get $i
    local.get $from
    i32.sub
    local.set $i
    i32.const 0
    local.get $i
    i32.sub
    local.get $i
    local.get $is_float
    select
    ref.i31)

  ;; -------------------------------------------------------------------------
  ;; Encoding primitives. The JavaScript host implements them.

  (func $prim.encoding.tison_encode (param eqref) (result eqref)
    local.get 0
    return_call $js.tison_encode)

  (func $prim.encoding.tison_decode (param eqref) (result eqref)
    local.get 0
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get 0
    return_call $js.tison_decode)

  (func $prim.encoding.base64_encode (param eqref eqref) (result eqref)
    local.get 0
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get 1
    call $check_bool
    br_on_non_null 0
    local.get 0
    local.get 1
    global.get $true
    ref.eq
    return_call $js.base64_encode)

  (func $prim.encoding.base64_decode (param eqref eqref) (result eqref)
    local.get 0
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get 1
    call $check_bool
    br_on_non_null 0
    local.get 0
    local.get 1
    global.get $true
    ref.eq
    return_call $js.base64_decode)

  ;; Checks that the argument is a boolean. Returns the failure or null.
  (func $check_bool (param $o eqref) (result (ref null $Failure))
    local.get $o
    global.get $true
    ref.eq
    local.get $o
    global.get $false
    ref.eq
    i32.or
    if
      ref.null $Failure
      return
    end
    global.get $ERR.WRONG_OBJECT_TYPE
    call $fail)

  ;; -------------------------------------------------------------------------
  ;; JavaScript interoperability (lib/js.toit). The JavaScript host
  ;; implements the calls. Like timers, calls are resources with integer ids.

  (func $prim.js.init (result eqref)
    i32.const 0
    ref.i31)

  (func $prim.js.eval (param eqref eqref) (result eqref)
    local.get 1
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    if
      call $blob_failure
      return
    end
    local.get 1
    return_call $js.js_eval)

  (func $prim.js.call_start (param eqref eqref eqref) (result eqref)
    local.get 1
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    local.get 2
    i32.const 0
    call $blob
    drop
    drop
    ref.is_null
    i32.or
    if
      call $blob_failure
      return
    end
    local.get 1
    local.get 2
    return_call $js.js_call_start)

  (func $prim.js.call_result (param eqref) (result eqref)
    local.get 0
    ref.test (ref i31)
    i32.eqz
    if
      global.get $ERR.WRONG_OBJECT_TYPE
      call $fail
      return
    end
    local.get 0
    return_call $js.js_call_result)

  ;; -------------------------------------------------------------------------
  ;; Slow paths of the operators, like the interpreter's INVOKE_* bytecodes.

  ;; Compares two numbers for a relational operator. Returns 0 or 1, or 2 if
  ;; they aren't both numbers and the operator method must be called.
  (func $relational_slow (param $a eqref) (param $b eqref) (param $bit i32) (result i32)
    (local $result i32)
    local.get $a
    local.get $b
    call $compare_numbers
    local.tee $result
    i32.eqz
    if
      i32.const 2
      return
    end
    local.get $result
    local.get $bit
    i32.and
    i32.const 0
    i32.ne)

  ;; Adds, subtracts, or multiplies (op 0, 1, 2) two floats. Returns null if
  ;; they aren't both floats.
  (func $float_arithmetic (param $a eqref) (param $b eqref) (param $op i32) (result eqref)
    (local $x f64) (local $y f64)
    local.get $a
    ref.test (ref $Float)
    local.get $b
    ref.test (ref $Float)
    i32.and
    i32.eqz
    if
      ref.null none
      return
    end
    local.get $a
    call $float_value
    local.set $x
    local.get $b
    call $float_value
    local.set $y
    local.get $op
    i32.eqz
    if
      local.get $x
      local.get $y
      f64.add
      call $float
      return
    end
    local.get $op
    i32.const 1
    i32.eq
    if
      local.get $x
      local.get $y
      f64.sub
      call $float
      return
    end
    local.get $x
    local.get $y
    f64.mul
    call $float)
