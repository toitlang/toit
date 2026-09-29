// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
 * JavaScript host for Toit programs that were compiled to WebAssembly GC
 * modules (see docs/wasm-gc-backend.md).
 *
 *   import { run } from "./toit-gc.mjs";
 *   const exitCode = await run(wasmBytes, { stdout: console.log });
 *
 * The host implements what the VM would otherwise provide: the message queue
 * of the process, timers, a minimal system process (service discovery and
 * trace printing), and task switching. Tasks run on their own WebAssembly
 * stacks, using JavaScript Promise Integration (JSPI).
 */

// Message types, see lib/core/message_.toit.
const SYSTEM_TRACE = 2;
const SYSTEM_RPC_REQUEST = 3;
const SYSTEM_RPC_REPLY = 4;

// RPC procedures of the system process, see lib/system/services.toit.
const RPC_SERVICES_OPEN = 300;

// The functions of the 'math' primitives, in the order of the runtime.
const MATH_FUNCTIONS = [
  Math.sin, Math.cos, Math.tan, Math.sinh, Math.cosh, Math.tanh, Math.asin,
  Math.acos, Math.atan, Math.sqrt, Math.exp, Math.log, Math.atan2, Math.pow,
];

// The syntax that strtod accepts (without leading white space).
const FLOAT_SYNTAX = /^[+-]?(([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?|0[xX]([0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)([pP][+-]?[0-9]+)?|[iI][nN][fF]([iI][nN][iI][tT][yY])?|[nN][aA][nN])$/;

function parseHexFloat(text) {
  const match = /^([+-]?)0x([0-9a-f]*)\.?([0-9a-f]*)(?:p([+-]?[0-9]+))?$/.exec(text);
  const mantissa = parseInt((match[2] || "0") + (match[3] || ""), 16);
  const exponent = parseInt(match[4] || "0", 10) - 4 * (match[3] || "").length;
  const value = mantissa * Math.pow(2, exponent);
  return match[1] === "-" ? -value : value;
}

// Formats a float like the Toit VM (see double_to_shortest in dtoa.cc): the
// shortest representation, like JavaScript, but integral values end in
// ".0", and exponents don't have a "+" and have at least two digits.
function toitFloatToString(value, precision) {
  if (Number.isNaN(value)) return "nan";
  if (value === Infinity) return "inf";
  if (value === -Infinity) return "-inf";
  if (precision >= 0) {
    // Like printf's "%.*lf", which doesn't switch to exponents.
    if (Math.abs(value) < 1e21) return value.toFixed(precision);
    const digits = BigInt(value).toString();
    return precision === 0 ? digits : `${digits}.${"0".repeat(precision)}`;
  }
  if (value === 0) return Object.is(value, -0) ? "-0.0" : "0.0";
  const sign = value < 0 ? "-" : "";
  const [mantissa, exponentText] = Math.abs(value).toExponential().split("e");
  const digits = mantissa.replace(".", "");
  const adjusted = parseInt(exponentText, 10);
  const exponent = adjusted - digits.length + 1;
  let result;
  if (-6 <= adjusted && adjusted < 21) {
    if (exponent >= 0) {
      result = `${digits}${"0".repeat(exponent)}.0`;
    } else if (adjusted >= 0) {
      result = `${digits.slice(0, adjusted + 1)}.${digits.slice(adjusted + 1)}`;
    } else {
      result = `0.${"0".repeat(-adjusted - 1)}${digits}`;
    }
  } else {
    const fraction = digits.length > 1 ? `.${digits.slice(1)}` : "";
    const exponentDigits = String(Math.abs(adjusted)).padStart(2, "0");
    result = `${digits[0]}${fraction}e${adjusted < 0 ? "-" : ""}${exponentDigits}`;
  }
  return sign + result;
}

// Extracts the Toit methods from a JavaScript stack trace. Compiled methods
// are named '$m<index>.<holder>.<name>', blocks '$b<index>.<method>'.
function toitStackTrace(stack) {
  const frames = [];
  for (const line of stack.split("\n")) {
    const match = /at (?:\$?)(m\d+|b\d+|g\d+)\.([^ ]*) \(wasm/.exec(line);
    if (!match) continue;
    let name = match[2];
    if (match[1].startsWith("b")) name = `[block] in ${name.replace(/^(l\.)?([bm]\d+\.)+/, "")}`;
    frames.push(name);
  }
  return frames.map((name, i) => `  ${String(i).padStart(2)}: ${name}`).join("\n");
}

// The error strings of the runtime (see '$ERR.*' in wasm_runtime.wat).
const ERROR = { WRONG_OBJECT_TYPE: 0, OUT_OF_BOUNDS: 1, OUT_OF_RANGE: 2, INVALID_ARGUMENT: 3 };

// TISON, the serialization format of the VM (see src/messaging.cc).
const TISON_MARKER = (0xa68900f7 | (1 << 8)) >>> 0;
const TISON_TAG = {
  POSITIVE_SMI: 1, NEGATIVE_SMI: 2, NULL: 3, TRUE: 4, FALSE: 5, ARRAY: 6, DOUBLE: 7,
  LARGE_INTEGER: 8, MAP: 9, STRING_INLINE: 11, BYTE_ARRAY_INLINE: 13,
};
const TISON_MAX_NESTING = 8;
// The small integers of 64-bit VMs. Larger integers are encoded as large
// integers.
const SMI_MIN = -(2n ** 62n);
const SMI_MAX = 2n ** 62n - 1n;

const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const BASE64_URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

class EncodingFailure extends Error {
  constructor(value) {
    super("encoding failure");
    this.value = value;
  }
}

class ByteWriter {
  constructor() {
    this.buffer = new Uint8Array(64);
    this.length = 0;
  }

  ensure(extra) {
    if (this.length + extra <= this.buffer.length) return;
    const grown = new Uint8Array(Math.max(this.buffer.length * 2, this.length + extra));
    grown.set(this.buffer.subarray(0, this.length));
    this.buffer = grown;
  }

  byte(value) {
    this.ensure(1);
    this.buffer[this.length++] = value;
  }

  bytes(values) {
    this.ensure(values.length);
    this.buffer.set(values, this.length);
    this.length += values.length;
  }

  cardinal(value) {
    while (value >= 128n) {
      this.byte(Number(value % 128n) + 128);
      value >>= 7n;
    }
    this.byte(Number(value));
  }

  uint32(value) {
    for (let i = 0; i < 4; i++) this.byte((value >>> (8 * i)) & 0xff);
  }

  uint64(value) {
    for (let i = 0n; i < 64n; i += 8n) this.byte(Number((value >> i) & 0xffn));
  }

  result() {
    return this.buffer.slice(0, this.length);
  }
}

class LineWriter {
  constructor(callback) {
    this.callback = callback;
    this.pending = "";
  }

  write(text) {
    const lines = (this.pending + text).split("\n");
    this.pending = lines.pop();
    for (const line of lines) this.callback(line);
  }

  flush() {
    if (this.pending !== "") this.callback(this.pending);
    this.pending = "";
  }
}

class ToitExit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

/**
 * Runs a compiled Toit program.
 *
 * @param {BufferSource} bytes The WebAssembly module.
 * @param {object} [options]
 * @param {(line: string) => void} [options.stdout] Called for each line on stdout.
 * @param {(line: string) => void} [options.stderr] Called for each line on stderr.
 * @param {string[]} [options.args] The arguments passed to the program's main.
 * @param {Object<string, Function>} [options.functions] Functions that the
 *     program can call with 'js.call', in addition to the global ones.
 * @returns {Promise<number>} The exit code.
 */
export async function run(bytes, options = {}) {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const stdout = new LineWriter(options.stdout ?? ((line) => console.log(line)));
  const stderr = new LineWriter(options.stderr ?? ((line) => console.error(line)));
  const missing = new Set();
  let exports = null;

  let resolveExit;
  let rejectExit;
  const exited = new Promise((resolve, reject) => {
    resolveExit = resolve;
    rejectExit = reject;
  });

  const systemTimeUs = () => (performance.timeOrigin + performance.now()) * 1000;
  const memoryBytes = (address, length) => new Uint8Array(exports.memory.buffer, address, length);
  const readString = (address, length) => decoder.decode(memoryBytes(address, length));
  const writeString = (text) => {
    const encoded = encoder.encode(text);
    exports.reserve_memory(encoded.length);
    memoryBytes(0, encoded.length).set(encoded);
    return encoded.length;
  };

  // Converts Toit values to JavaScript values.
  const toJs = (value) => {
    switch (exports.value_kind(value)) {
      case 0: return null;
      case 1: return exports.int_value(value);
      case 2: return exports.float_value(value);
      case 3: return readString(0, exports.bytes_to_memory(value));
      case 4: return memoryBytes(0, exports.bytes_to_memory(value)).slice();
      case 5: {
        const length = exports.array_length(value);
        const result = [];
        for (let i = 0; i < length; i++) result.push(toJs(exports.array_get(value, i)));
        return result;
      }
      case 6: return true;
      case 7: return false;
      case 9: {
        const size = exports.list_size(value);
        const backing = toJs(exports.list_array(value));
        return Array.isArray(backing) ? backing.slice(0, size) : backing;
      }
      default: return value;
    }
  };

  // Describes a converted value for messages. Toit objects that couldn't be
  // converted are opaque to JavaScript.
  const describe = (value) => {
    if (Array.isArray(value)) return value.map(describe).join(", ");
    if (value !== null && typeof value === "object" && !(value instanceof Uint8Array)) {
      return "<object>";
    }
    return String(value);
  };

  // Converts JavaScript values to Toit values.
  const toToit = (value) => {
    if (value === null || value === undefined) return null;
    if (typeof value === "boolean") return exports.new_boolean(value ? 1 : 0);
    if (typeof value === "number") {
      return Number.isInteger(value) ? exports.new_int(value) : exports.new_float(value);
    }
    if (typeof value === "string") return exports.new_string(writeString(value));
    if (value instanceof Uint8Array) {
      exports.reserve_memory(value.length);
      memoryBytes(0, value.length).set(value);
      return exports.new_byte_array(value.length);
    }
    if (Array.isArray(value)) {
      const result = exports.new_array(value.length);
      value.forEach((element, i) => exports.array_set(result, i, toToit(element)));
      return result;
    }
    // Toit objects that JavaScript holds on to.
    return value;
  };

  // The message queue of the process. Messages are Toit objects: arrays for
  // system messages, and monitors for notifications.
  const messages = [];
  let messageWaiters = [];
  const enqueue = (message) => {
    messages.push(message);
    const waiters = messageWaiters;
    messageWaiters = [];
    for (const resolve of waiters) resolve();
  };

  // A minimal system process. It answers the RPC calls of the service
  // framework as if there were no services, and prints traces.
  const systemRpc = (name, args) => {
    if (name === RPC_SERVICES_OPEN) {
      // [id, uuid, major, minor] -> [client-id, name, major, minor, patch, tags].
      return [1, "system", args[2], args[3], 0, null];
    }
    // Service discovery finds nothing, and all other calls succeed.
    return null;
  };
  const debug = globalThis.process?.env?.TOIT_GC_DEBUG ? (...args) => console.error("[debug]", ...args) : () => {};
  // The errors of the byte arrays that 'encode_error' returns.
  const errorTraces = new WeakMap();
  const processSend = (pid, type, message) => {
    debug("process_send", pid, type, JSON.stringify(toJs(message)));
    if (pid !== -1) return 0;  // Only the system process exists.
    if (type === SYSTEM_TRACE) {
      const error = errorTraces.get(message);
      if (error) {
        stderr.write(`${describe(toJs(error.type))} error. \n${describe(toJs(error.message))}\n`);
        stderr.write(`${toitStackTrace(error.error.stack)}\n`);
      } else {
        const trace = toJs(message);
        stderr.write(typeof trace === "string" ? trace : decoder.decode(trace));
      }
      return 1;
    }
    if (type === SYSTEM_RPC_REQUEST) {
      const [id, name, args] = toJs(message);
      const result = systemRpc(name, args);
      enqueue(toToit([SYSTEM_RPC_REPLY, 0, -1, [id, false, result, null]]));
      return 1;
    }
    // Other messages to the system process are ignored.
    return 1;
  };

  // Resources (timers) with their notification monitors and states.
  let nextResourceId = 1;
  const resources = new Map();
  const notify = (resource) => {
    resource.state |= 1;
    if (resource.monitor) enqueue(resource.monitor);
  };
  const armedTimers = new Set();
  const expireTimer = (resource) => {
    clearTimeout(resource.timeout);
    resource.timeout = null;
    armedTimers.delete(resource);
    notify(resource);
  };
  const pollTimers = () => {
    if (armedTimers.size === 0) return;
    const now = systemTimeUs();
    for (const resource of armedTimers) {
      if (resource.deadline <= now) expireTimer(resource);
    }
  };

  // Tasks. Every task runs in its own call of the promising 'run_task'
  // export, so it has its own stack. Suspending imports switch between them.
  let nextTaskId = 1;
  const newTasks = new Map();   // Task -> lambda, for tasks that haven't started.
  const suspended = new Map();  // Task -> resolve function of a suspended task.
  let currentTask = null;
  let runTask = null;

  const handleTaskError = (error) => {
    if (error instanceof ToitExit) {
      resolveExit(error.code);
    } else {
      rejectExit(error);
    }
  };

  const switchTo = (task) => {
    queueMicrotask(() => {
      const resume = suspended.get(task);
      if (resume) {
        suspended.delete(task);
        resume();
        return;
      }
      const lambda = newTasks.get(task);
      newTasks.delete(task);
      runTask(task, lambda).catch(handleTaskError);
    });
  };

  let exitCode = null;
  // Primitives of the 'encoding' module. They get checked arguments and
  // return the result, or a failure created with 'exports.fail' or
  // 'exports.failure'.
  const blobBytes = (value) => memoryBytes(0, exports.bytes_to_memory(value)).slice();
  const newToitBytes = (bytes, isString) => {
    exports.reserve_memory(bytes.length);
    memoryBytes(0, bytes.length).set(bytes);
    return isString ? exports.new_string(bytes.length) : exports.new_byte_array(bytes.length);
  };
  const tisonEncode = (object) => {
    const writer = new ByteWriter();
    const fail = (value) => { throw new EncodingFailure(value); };
    const encodeArray = (array, from, to, nesting) => {
      writer.byte(TISON_TAG.ARRAY);
      writer.cardinal(BigInt(to - from));
      for (let i = from; i < to; i++) encode(exports.array_get(array, i), nesting);
    };
    const encodeList = (list, from, to, nesting) => {
      const backing = exports.list_array(list);
      // Large arrays aren't supported, like in the VM.
      if (exports.value_kind(backing) !== 5) fail(exports.fail(ERROR.WRONG_OBJECT_TYPE));
      encodeArray(backing, from, to, nesting);
    };
    const smallInt = (value) => {
      if (exports.value_kind(value) !== 1) fail(exports.fail(ERROR.WRONG_OBJECT_TYPE));
      const result = exports.int64_value(value);
      if (result < -(2n ** 31n) || result >= 2n ** 31n) fail(exports.fail(ERROR.WRONG_OBJECT_TYPE));
      return Number(result);
    };
    const encode = (value, nesting) => {
      nesting++;
      if (nesting > TISON_MAX_NESTING) fail(exports.failure(toToit("NESTING_TOO_DEEP")));
      const kind = exports.value_kind(value);
      switch (kind) {
        case 0: writer.byte(TISON_TAG.NULL); return;
        case 6: writer.byte(TISON_TAG.TRUE); return;
        case 7: writer.byte(TISON_TAG.FALSE); return;
        case 1: {
          const integer = exports.int64_value(value);
          if (integer >= 0n && integer <= SMI_MAX) {
            writer.byte(TISON_TAG.POSITIVE_SMI);
            writer.cardinal(integer);
          } else if (integer < 0n && integer >= SMI_MIN) {
            writer.byte(TISON_TAG.NEGATIVE_SMI);
            writer.cardinal(-integer);
          } else {
            writer.byte(TISON_TAG.LARGE_INTEGER);
            writer.uint64(BigInt.asUintN(64, integer));
          }
          return;
        }
        case 2: {
          const view = new DataView(new ArrayBuffer(8));
          view.setFloat64(0, exports.float_value(value), true);
          writer.byte(TISON_TAG.DOUBLE);
          writer.uint64(view.getBigUint64(0, true));
          return;
        }
        case 3:
        case 4: {
          const bytes = blobBytes(value);
          writer.byte(kind === 3 ? TISON_TAG.STRING_INLINE : TISON_TAG.BYTE_ARRAY_INLINE);
          writer.cardinal(BigInt(bytes.length));
          writer.bytes(bytes);
          return;
        }
        case 5: encodeArray(value, 0, exports.array_length(value), nesting); return;
        case 9: encodeList(value, 0, exports.list_size(value), nesting); return;
        case 10: {
          const size = smallInt(exports.map_size(value));
          writer.byte(TISON_TAG.MAP);
          writer.cardinal(BigInt(size));
          if (size === 0) return;
          let backing = exports.map_backing(value);
          if (exports.value_kind(backing) === 9) backing = exports.list_array(backing);
          if (exports.value_kind(backing) !== 5) fail(exports.fail(ERROR.WRONG_OBJECT_TYPE));
          for (let i = 0, count = 0; count < size; i += 2) {
            const key = exports.array_get(backing, i);
            if (exports.value_kind(key) === 12) continue;  // A deleted entry.
            encode(key, nesting);
            encode(exports.array_get(backing, i + 1), nesting);
            count++;
          }
          return;
        }
        case 11: {
          const from = smallInt(exports.list_slice_from(value));
          const to = smallInt(exports.list_slice_to(value));
          const list = exports.list_slice_list(value);
          const listKind = exports.value_kind(list);
          if (listKind === 5) return encodeArray(list, from, to, nesting);
          if (listKind === 9) return encodeList(list, from, to, nesting);
          if (listKind === 8) fail(exports.failure(toToit([exports.class_id(list)])));
          fail(exports.fail(ERROR.WRONG_OBJECT_TYPE));
        }
        case 8: fail(exports.failure(toToit([exports.class_id(value)])));
        default: fail(exports.fail(ERROR.WRONG_OBJECT_TYPE));
      }
    };
    try {
      encode(object, 0);
    } catch (error) {
      if (error instanceof EncodingFailure) return error.value;
      throw error;
    }
    const payload = writer.result();
    const result = new ByteWriter();
    result.uint32(TISON_MARKER);
    result.cardinal(BigInt(payload.length));
    result.bytes(payload);
    return newToitBytes(result.result(), false);
  };
  const tisonDecode = (data) => {
    const bytes = blobBytes(data);
    const view = new DataView(bytes.buffer);
    let cursor = 0;
    const malformed = () => { throw new EncodingFailure(exports.fail(ERROR.WRONG_OBJECT_TYPE)); };
    const byte = () => {
      if (cursor >= bytes.length) malformed();
      return bytes[cursor++];
    };
    const cardinal = () => {
      let result = 0n;
      let shift = 0n;
      let next = byte();
      while (next >= 128) {
        result += BigInt(next - 128) << shift;
        shift += 7n;
        next = byte();
      }
      return BigInt.asUintN(64, result + (BigInt(next) << shift));
    };
    const length = () => {
      const result = cardinal();
      if (result > BigInt(bytes.length - cursor)) malformed();
      return Number(result);
    };
    const uint64 = () => {
      if (cursor + 8 > bytes.length) malformed();
      cursor += 8;
      return view.getBigUint64(cursor - 8, true);
    };
    const decode = () => {
      const tag = byte();
      switch (tag) {
        case TISON_TAG.POSITIVE_SMI: return exports.new_int64(BigInt.asIntN(64, cardinal()));
        case TISON_TAG.NEGATIVE_SMI: return exports.new_int64(BigInt.asIntN(64, -cardinal()));
        case TISON_TAG.NULL: return null;
        case TISON_TAG.TRUE: return exports.new_boolean(1);
        case TISON_TAG.FALSE: return exports.new_boolean(0);
        case TISON_TAG.STRING_INLINE:
        case TISON_TAG.BYTE_ARRAY_INLINE: {
          const size = length();
          cursor += size;
          return newToitBytes(bytes.subarray(cursor - size, cursor), tag === TISON_TAG.STRING_INLINE);
        }
        case TISON_TAG.ARRAY: {
          const size = length();
          const result = exports.new_array(size);
          for (let i = 0; i < size; i++) exports.array_set(result, i, decode());
          return result;
        }
        case TISON_TAG.MAP: {
          const size = length();
          if (size === 0) return exports.new_map(0, null);
          const backing = exports.new_array(size * 2);
          for (let i = 0; i < size * 2; i++) exports.array_set(backing, i, decode());
          return exports.new_map(size, backing);
        }
        case TISON_TAG.DOUBLE: {
          const bits = uint64();
          const buffer = new DataView(new ArrayBuffer(8));
          buffer.setBigUint64(0, bits, true);
          return exports.new_float(buffer.getFloat64(0, true));
        }
        case TISON_TAG.LARGE_INTEGER: return exports.new_int64(BigInt.asIntN(64, uint64()));
        default: malformed();
      }
    };
    try {
      if (bytes.length < 4 || view.getUint32(0, true) !== TISON_MARKER) malformed();
      cursor = 4;
      if (cardinal() !== BigInt(bytes.length - cursor)) malformed();
      const result = decode();
      if (cursor !== bytes.length) malformed();
      return result;
    } catch (error) {
      if (error instanceof EncodingFailure) return error.value;
      throw error;
    }
  };
  const base64Encode = (data, urlMode) => {
    const alphabet = urlMode ? BASE64_URL_ALPHABET : BASE64_ALPHABET;
    const bytes = blobBytes(data);
    let result = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const count = Math.min(3, bytes.length - i);
      const word = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
      for (let j = 0; j <= count; j++) result += alphabet[(word >> (18 - 6 * j)) & 0x3f];
      if (!urlMode) result += "=".repeat(3 - count);
    }
    return toToit(result);
  };
  const base64Decode = (data, urlMode) => {
    // Like the VM (see primitive_encoding.cc).
    const input = blobBytes(data);
    const outOfRange = () => exports.fail(ERROR.OUT_OF_RANGE);
    const length = input.length;
    let outLength = (length >> 2) * 3;
    if (urlMode) {
      if ((length & 3) === 1) return outOfRange();
      if ((length & 3) === 2) outLength += 1;
      if ((length & 3) === 3) outLength += 2;
    } else {
      if ((length & 3) !== 0) return outOfRange();
      if (length > 0 && input[length - 1] === 0x3d) outLength--;
      if (length > 1 && input[length - 2] === 0x3d) outLength--;
    }
    const value = (index) => {
      const c = String.fromCharCode(input[index]);
      const alphabet = urlMode ? BASE64_URL_ALPHABET : BASE64_ALPHABET;
      const result = alphabet.indexOf(c);
      return result < 0 ? -1 : result;
    };
    const decodeGroup = (from, count) => {
      let word = 0;
      for (let k = 0; k < count; k++) word = (word << 6) | value(from + k);
      // A '-1' sets the high bits.
      return word;
    };
    const result = new Uint8Array(outLength);
    let i = 0;
    let j = 0;
    for (; i <= outLength - 3; i += 3, j += 4) {
      const word = decodeGroup(j, 4);
      if (word < 0 || (word >>> 24) !== 0) return outOfRange();
      result[i] = (word >> 16) & 0xff;
      result[i + 1] = (word >> 8) & 0xff;
      result[i + 2] = word & 0xff;
    }
    j = Math.floor(outLength / 3) * 4;
    if (outLength % 3 === 1) {
      if (!urlMode && (input[j + 2] !== 0x3d || input[j + 3] !== 0x3d)) return outOfRange();
      const word = decodeGroup(j, 2);
      if (word < 0 || (word & 0xf) !== 0) return outOfRange();
      result[outLength - 1] = (word >> 4) & 0xff;
    } else if (outLength % 3 === 2) {
      if (!urlMode && input[j + 3] !== 0x3d) return outOfRange();
      const word = decodeGroup(j, 3);
      if (word < 0 || (word & 0x3) !== 0) return outOfRange();
      result[outLength - 2] = (word >> 10) & 0xff;
      result[outLength - 1] = (word >> 2) & 0xff;
    }
    return newToitBytes(result, false);
  };

  // JavaScript interoperability (lib/js.toit), like the Emscripten VM
  // (src/wasm/library_toit.js). Values cross the boundary as JSON.
  const jsonStringify = (value) => JSON.stringify(value) ?? "null";
  const errorJson = (error) => JSON.stringify(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
  const newCallResource = () => {
    const id = nextResourceId++;
    const resource = { monitor: null, state: 0, result: null };
    resources.set(id, resource);
    return [id, resource];
  };
  const jsEval = (code) => {
    const [id, resource] = newCallResource();
    try {
      // Indirect eval, so the code runs in the global scope.
      resource.result = [false, jsonStringify((0, eval)(toJs(code)))];
    } catch (error) {
      resource.result = [true, errorJson(error)];
    }
    resource.state = 1;
    return toToit(id);
  };
  const jsCallStart = (name, args) => {
    const [id, resource] = newCallResource();
    const functionName = toJs(name);
    let promise;
    try {
      // Functions provided by the embedder take precedence over globals.
      // Dotted names, like 'Math.max', are resolved property by property,
      // and the function is called with its parent object as receiver.
      const functions = options.functions ?? {};
      let receiver = undefined;
      let fn = functions[functionName];
      if (fn === undefined) {
        const path = functionName.split(".");
        fn = path[0] in functions ? functions : globalThis;
        for (const key of path) {
          receiver = fn;
          fn = fn?.[key];
        }
      }
      if (typeof fn !== "function") throw new TypeError(`'${functionName}' is not a function`);
      promise = Promise.resolve(fn.apply(receiver, JSON.parse(toJs(args))));
    } catch (error) {
      promise = Promise.reject(error);
    }
    // The result is always delivered asynchronously.
    const complete = (isError, json) => {
      resource.result = [isError, json];
      notify(resource);
    };
    promise.then((value) => {
      let json;
      try {
        json = jsonStringify(value);
      } catch (error) {
        complete(true, errorJson(error));
        return;
      }
      complete(false, json);
    }, (error) => complete(true, errorJson(error)));
    return toToit(id);
  };
  const jsCallResult = (id) => {
    const resource = resources.get(toJs(id));
    if (!resource?.result) return exports.fail(ERROR.WRONG_OBJECT_TYPE);
    resources.delete(toJs(id));
    return toToit(resource.result);
  };

  const imports = {
    toit: {
      write: (fd, address, length) => {
        (fd === 2 ? stderr : stdout).write(readString(address, length));
      },
      exit: (code) => {
        if (globalThis.process?.env?.TOIT_GC_DEBUG) console.error(`exit ${code}`, new Error().stack);
        exitCode = code;
      },
      // Both clocks are monotonic, like OS::get_monotonic_time and
      // OS::get_system_time. Timers use the system time.
      now_us: () => performance.now() * 1000,
      time_us: () => systemTimeUs(),
      random: () => (Math.random() * 0x100000000) | 0,
      missing_primitive: (address, length) => {
        const name = readString(address, length);
        if (missing.has(name)) return;
        missing.add(name);
        stderr.write(`[wasm-gc: missing primitive ${name}]\n`);
      },
      float_to_string: (value, precision) => writeString(toitFloatToString(value, precision)),
      string_to_float: (address, length) => Number(readString(address, length)),
      fmod: (a, b) => a % b,
      // C's round: halfway cases away from zero.
      round: (x) => Math.sign(x) * Math.round(Math.abs(x)),

      yield: new WebAssembly.Suspending(async () => {
        if (messages.length > 0) return;
        await new Promise((resolve) => messageWaiters.push(resolve));
      }),
      transfer: new WebAssembly.Suspending(async (to, detach) => {
        const from = currentTask;
        currentTask = to;
        switchTo(to);
        // A detached task terminated. Its stack is never resumed.
        if (detach) return new Promise(() => {});
        await new Promise((resolve) => suspended.set(from, resolve));
        currentTask = from;
        return from;
      }),
      task_new: (task, lambda) => {
        newTasks.set(task, lambda);
        return nextTaskId++;
      },
      main_arguments: () => toToit(options.args ?? []),
      math: (op, x, y) => MATH_FUNCTIONS[op](x, y),
      parse_float: (address, length) => {
        // Like strtod, but the whole input must be consumed.
        const text = readString(address, length);
        if (!FLOAT_SYNTAX.test(text)) return [NaN, 0];
        const lower = text.toLowerCase();
        if (lower.endsWith("nan")) return [NaN, 1];
        if (lower.endsWith("inf") || lower.endsWith("infinity")) {
          return [lower.startsWith("-") ? -Infinity : Infinity, 1];
        }
        if (lower.replace(/^[+-]/, "").startsWith("0x")) {
          return [parseHexFloat(lower), 1];
        }
        return [Number(text), 1];
      },
      get_env: (length) => {
        const name = readString(0, length);
        const value = globalThis.process?.env?.[name];
        if (value === undefined) return -1;
        return writeString(value);
      },
      time_info: (seconds, isUtc) => {
        const date = new Date(seconds * 1000);
        const utc = isUtc !== 0;
        const year = utc ? date.getUTCFullYear() : date.getFullYear();
        const start = utc ? Date.UTC(year, 0, 1) : new Date(year, 0, 1).getTime();
        const values = utc
          ? [date.getUTCSeconds(), date.getUTCMinutes(), date.getUTCHours(), date.getUTCDate(),
             date.getUTCMonth(), year, date.getUTCDay()]
          : [date.getSeconds(), date.getMinutes(), date.getHours(), date.getDate(),
             date.getMonth(), year, date.getDay()];
        values.push(Math.floor((date.getTime() - start) / 86400000));
        // Daylight saving time: the offset is smaller than in January or July.
        const january = new Date(year, 0, 1).getTimezoneOffset();
        const july = new Date(year, 6, 1).getTimezoneOffset();
        values.push(!utc && date.getTimezoneOffset() < Math.max(january, july) ? 1 : 0);
        exports.reserve_memory(36);
        const view = new DataView(exports.memory.buffer);
        values.forEach((value, i) => view.setInt32(i * 4, value, true));
      },
      has_messages: () => {
        // Programs that don't yield to the event loop still see their
        // timers expire, like with the VM's timer thread.
        if (messages.length === 0) pollTimers();
        return messages.length > 0 ? 1 : 0;
      },
      receive_message: () => {
        debug("receive_message", messages.length);
        return messages.shift() ?? null;
      },
      process_send: processSend,
      encode_error: (type, message) => {
        // Formatting stack traces is expensive, and most traces are never
        // printed. Remember the error for the returned byte array, and
        // format the trace when the byte array is sent to the system process.
        const limit = Error.stackTraceLimit;
        Error.stackTraceLimit = 20;
        const error = new Error();
        Error.stackTraceLimit = limit;
        const result = exports.new_byte_array(0);
        errorTraces.set(result, { type, message, error });
        return result;
      },

      timer_create: () => {
        const id = nextResourceId++;
        resources.set(id, { monitor: null, state: 0, timeout: null });
        return id;
      },
      timer_arm: (id, deadline) => {
        const resource = resources.get(id);
        clearTimeout(resource.timeout);
        resource.state = 0;
        const delay = Math.max(0, (deadline - systemTimeUs()) / 1000);
        resource.deadline = deadline;
        resource.timeout = setTimeout(() => expireTimer(resource), delay);
        armedTimers.add(resource);
      },
      timer_delete: (id) => {
        const resource = resources.get(id);
        if (resource) {
          clearTimeout(resource.timeout);
          armedTimers.delete(resource);
        }
        resources.delete(id);
      },
      register_monitor_notifier: (monitor, id) => {
        const resource = resources.get(id);
        if (!resource) return;
        resource.monitor = monitor;
        if (monitor && resource.state !== 0) enqueue(monitor);
      },
      unregister_monitor_notifier: (id) => {
        const resource = resources.get(id);
        if (resource) resource.monitor = null;
      },
      read_state: (id) => {
        const resource = resources.get(id);
        if (!resource) return 0;
        const state = resource.state;
        resource.state = 0;
        return state;
      },
      tison_encode: tisonEncode,
      tison_decode: tisonDecode,
      base64_encode: base64Encode,
      base64_decode: base64Decode,
      js_eval: jsEval,
      js_call_start: jsCallStart,
      js_call_result: jsCallResult,
    },
  };

  const { instance } = await WebAssembly.instantiate(bytes, imports);
  exports = instance.exports;
  runTask = WebAssembly.promising(exports.run_task);
  const main = WebAssembly.promising(exports.main);

  const wrapTrap = (error) => {
    // Exiting traps, so no finally handlers run.
    if (exitCode !== null) throw new ToitExit(exitCode);
    // Engines don't let WebAssembly code catch stack overflows, so Toit's
    // 'catch' can't see them. Report them like an uncaught Toit exception.
    if (error instanceof RangeError && /call stack/i.test(error.message)) {
      stdout.flush();
      stderr.write("******************************************************************************\n");
      stderr.write("EXCEPTION error.\nSTACK_OVERFLOW\n");
      stderr.write("******************************************************************************\n");
      throw new ToitExit(1);
    }
    throw error;
  };
  runTask = ((original) => (task, lambda) => original(task, lambda).catch(wrapTrap))(runTask);

  currentTask = exports.create_main_task();
  main(currentTask)
      .then(() => resolveExit(exitCode ?? 0))
      .catch(wrapTrap)
      .catch(handleTaskError);
  try {
    return await exited;
  } finally {
    stdout.flush();
    stderr.flush();
    for (const resource of resources.values()) clearTimeout(resource.timeout);
  }
}
