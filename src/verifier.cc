// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Structural bytecode verifier.
//
// Overview:
//   * Phase 0 walks the program heap and checks the program tables
//     (dispatch table, class tables, entry points, literals, globals).
//   * Every method reachable from the dispatch table, the entry points,
//     the lazy global initializers and LOAD_METHOD operands is verified by
//     an abstract interpretation over a small lattice of "slot kinds"
//     (see Kind below). Heights, slot kinds and branch targets are
//     computed per instruction; states reaching the same instruction must
//     be identical ("strict merge"), as in the Java verifier.
//   * Blocks are verified in the context of the frame that creates them
//     (the LOAD_METHOD site), so LOAD_OUTER / STORE_OUTER / non-local
//     returns and branches can be checked against the outer frame layout.
//   * Which parameters of a method must hold blocks is inferred with a
//     monotone fixpoint over all methods (required_mask); a compiler-emitted
//     declaration would make this a single pass.
//   * The receivers of field accesses are tracked with a small lattice, but
//     only as diagnostics: the interpreter checks the field accesses of
//     untrusted processes at run time (of all processes when built with
//     TOIT_CHECKED_FIELD_ACCESS). Unproven receivers are warnings (errors
//     with VerifierOptions::strict).

#include "verifier.h"
#include "primitive_policy.h"

#if !defined(TOIT_FREERTOS)

#include <algorithm>
#include <stdarg.h>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "bytecodes.h"
#include "entry_points.h"
#include "flags.h"
#include "interpreter.h"
#include "method_entries.h"
#include "objects.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "program.h"

namespace toit {

#define BYTECODE_LENGTH(name, length, format, print) length,
static const int kOpcodeLength[] = { BYTECODES(BYTECODE_LENGTH) };
#undef BYTECODE_LENGTH

#define BYTECODE_NAME(name, length, format, print) #name,
static const char* const kOpcodeName[] = { BYTECODES(BYTECODE_NAME) };
#undef BYTECODE_NAME

// Static primitive tables (sizes and arities) derived from primitive.h, so
// that the checks do not depend on which modules are linked in.
#define COUNT_PRIMITIVE(name, arity) + 1
#define MODULE_SIZE(name, entries) entries(COUNT_PRIMITIVE) + 0,
static const int kPrimitiveModuleSizes[] = { MODULES(MODULE_SIZE) };
#undef MODULE_SIZE
#undef COUNT_PRIMITIVE

#define PRIMITIVE_ARITY(name, arity) arity,
#define MODULE_ARITIES(name, entries) static const int name##_primitive_arities[] = { entries(PRIMITIVE_ARITY) };
MODULES(MODULE_ARITIES)
#undef MODULE_ARITIES
#define MODULE_ARITY_TABLE(name, entries) name##_primitive_arities,
static const int* const kPrimitiveArities[] = { MODULES(MODULE_ARITY_TABLE) };
#undef MODULE_ARITY_TABLE
#undef PRIMITIVE_ARITY

static const int kPrimitiveModuleCount = sizeof(kPrimitiveModuleSizes) / sizeof(kPrimitiveModuleSizes[0]);

// Primitive names, for the list of referenced primitives.
#define PRIMITIVE_NAME(name, arity) #name,
#define MODULE_NAMES(name, entries) static const char* const name##_primitive_names[] = { entries(PRIMITIVE_NAME) };
MODULES(MODULE_NAMES)
#undef MODULE_NAMES
#define MODULE_NAME_TABLE(name, entries) name##_primitive_names,
static const char* const* const kPrimitiveNames[] = { MODULES(MODULE_NAME_TABLE) };
#undef MODULE_NAME_TABLE
#undef PRIMITIVE_NAME
#define MODULE_NAME(name, entries) #name,
static const char* const kPrimitiveModuleNames[] = { MODULES(MODULE_NAME) };
#undef MODULE_NAME

static const int FRAME_SIZE = Interpreter::FRAME_SIZE;
static const int METHOD_HEADER_SIZE = Method::entry_offset();
static const int MAX_PASSES = 16;
static const int MAX_REPORTED_ERRORS = 40;

// ----------------------------------------------------------------------------
// Abstract values.

enum Kind : uint8 {
  K_ANY = 0,      // Any object (smi or heap object).
  K_PARAM,        // Unmodified copy of a parameter; semantically ANY. aux = (method id << 8) | index.
  K_THIS,         // Receiver of a virtual-only method. aux = method id. Classes from the dispatch table.
  K_RANGE,        // Instance of a class in class_check_ids[aux], declared by the method header. Immutable.
  K_CHECKED,      // Instance of a class in class_check_ids[aux], established by a passed as-check. Mutable.
  K_ALLOC,        // Result of ALLOCATE. aux = class id.
  K_METHOD_ID,    // Slot that LOAD_METHOD filled with a block method id. aux = context id. Immutable.
  K_BLOCK,        // Block reference. aux = context id, 0 if opaque (came in as a parameter).
  K_LINK_RESULT,  // The four slots pushed by LINK (try/finally). Immutable.
  K_LINK_TARGET,
  K_LINK_REASON,
  K_LINK_CHAIN,
  K_FRAME,        // Frame marker / return address. Never accessible.
};

static const char* kind_name(int kind) {
  switch (kind) {
    case K_ANY: return "any";
    case K_PARAM: return "param";
    case K_THIS: return "this";
    case K_RANGE: return "range";
    case K_CHECKED: return "checked";
    case K_ALLOC: return "alloc";
    case K_METHOD_ID: return "method-id";
    case K_BLOCK: return "block";
    case K_LINK_RESULT: return "link-result";
    case K_LINK_TARGET: return "link-target";
    case K_LINK_REASON: return "link-reason";
    case K_LINK_CHAIN: return "link-chain";
    case K_FRAME: return "frame";
  }
  return "?";
}

struct Slot {
  uint8 kind;
  uint8 captured;  // Method-id slots: a nested block loads this slot with LOAD_OUTER_BLOCK.
  uint32 aux;
  static Slot make(Kind kind, uint32 aux = 0) { Slot s; s.kind = kind; s.captured = 0; s.aux = aux; return s; }
  static Slot any() { return make(K_ANY); }
  bool same(const Slot& other) const { return kind == other.kind && aux == other.aux; }
  bool is_link() const { return kind >= K_LINK_RESULT && kind <= K_LINK_CHAIN; }
  bool is_immutable() const { return kind == K_METHOD_ID || is_link() || kind == K_FRAME; }
};

// Abstract frame: the expression stack (bottom first) and the parameters.
struct State {
  std::vector<Slot> stack;
  std::vector<Slot> params;

  int height() const { return static_cast<int>(stack.size()); }
  int arity() const { return static_cast<int>(params.size()); }

  // Resolves STACK_AT(index) (0 = top). Returns null for frame slots or
  // indexes outside the frame; *frame is set when a frame slot was hit.
  Slot* at(int index, bool* frame) {
    *frame = false;
    int h = height();
    if (index < 0) return null;
    if (index < h) return &stack[h - 1 - index];
    if (index < h + FRAME_SIZE) { *frame = true; return null; }
    int p = index - h - FRAME_SIZE;
    if (p >= arity()) return null;
    return &params[arity() - 1 - p];
  }

  bool same(const State& other) const {
    if (stack.size() != other.stack.size() || params.size() != other.params.size()) return false;
    for (size_t i = 0; i < stack.size(); i++) if (!stack[i].same(other.stack[i])) return false;
    for (size_t i = 0; i < params.size(); i++) if (!params[i].same(other.params[i])) return false;
    return true;
  }
};

struct MethodRun;

// The frame layout a block was created in. Block references carry the id
// of their context, so LOAD_OUTER & co. can be checked against this.
struct Context {
  int id;
  int block_method;    // The block method that was loaded.
  int owner_method;    // The method whose frame this is.
  int owner_arity;
  MethodRun* owner;    // The verification run of the owner; alive while the block is verified.
  State state;         // Owner frame right after LOAD_METHOD (the method-id token is the top slot).
  std::vector<int> block_accesses;  // Outer slot indexes used by LOAD_OUTER_BLOCK in nested blocks.
};

struct MethodInfo {
  uint64 required_mask = 0;   // Bit n set: parameter n must be a block.
  bool static_target = false; // Reached by INVOKE_STATIC, LOAD_METHOD (lambdas), entry points or lazy init.
  bool entry_point = false;
  bool never_returns = false; // Every path throws (or calls a never-returning static method).
  bool seen_in_pass = false;
  int load_site = -1;         // Blocks: the single LOAD_METHOD site that loads them.
  std::vector<int> receiver_classes;  // Virtual dispatch receiver classes (selector_offset >= 0).
};

struct MethodRun {
  int method_id;
  Method method = Method::invalid();
  int entry_bci;
  Context* context;    // Non-null when verifying a block method.
  std::unordered_map<int, State> entries;
  std::unordered_map<int, Context*> site_contexts;  // LOAD_METHOD bci -> context.
  std::vector<int> worklist;
  int depth = 0;       // Lexical nesting depth (0 = method, 1 = block in it, ...).
  int max_height = 0;
  bool aborted = false;
  bool may_return = false;
  bool had_error = false;
};

// ----------------------------------------------------------------------------

class VerifierImpl {
 public:
  VerifierImpl(Program* program, VerifierStats* stats, const VerifierOptions& options)
      : program_(program), stats_(stats), verbosity_(options.verbosity), untrusted_(options.untrusted),
        strict_(options.strict), print_primitives_(options.print_primitives) {
    bytecodes_ = program->bytecodes.data();
    bytecodes_length_ = program->bytecodes.length();
    if (override_program_ == program && override_bytecodes_ != null) {
      // Testing: the program image is read-only, so the override lives outside of it.
      bytecodes_ = override_bytecodes_;
      bytecodes_length_ = override_length_;
    }
    class_count_ = program->class_bits.length();
    dispatch_length_ = program->dispatch_table.length();
  }

  bool run();

  static void set_bytecodes(Program* program, uint8* bytes, int length) {
    override_program_ = program;
    override_bytecodes_ = bytes;
    override_length_ = length;
  }
  static Program* override_program_;
  static uint8* override_bytecodes_;
  static int override_length_;
  static uint8* coverage_;

 private:
  Program* const program_;
  VerifierStats* const stats_;
  const int verbosity_;
  const bool untrusted_;
  const bool strict_;
  const bool print_primitives_;

  // Program heap.
  std::unordered_set<uword> heap_objects_;    // Untagged start addresses of all heap objects.
  std::vector<HeapObject*> heap_instances_;   // INSTANCE_TAG objects, for the method-id checks.
  std::unordered_set<int> lambda_classes_;    // Receiver classes of methods using INVOKE_LAMBDA_TAIL.
  uword image_begin_ = 0;
  uword image_end_ = 0;
  bool heap_walked_ = false;

  static uword address_of(Object* object) { return reinterpret_cast<uword>(object) & ~static_cast<uword>(3); }
  bool is_heap_reference(Object* object) const {
    return is_smi(object) || (is_heap_object(object) && heap_objects_.count(address_of(object)) != 0);
  }
  bool walk_heap();
  bool check_builtin_classes();
  bool check_heap_method_ids();

  uint8* bytecodes_;
  int bytecodes_length_;
  int class_count_;
  int dispatch_length_;

  int pass_ = 0;
  bool changed_ = false;
  bool final_pass_ = false;
  std::vector<std::string> errors_;
  std::vector<std::string> warnings_;
  std::unordered_map<int, MethodInfo> infos_;
  std::unordered_map<int, std::vector<int>> selector_targets_;  // selector offset -> method ids.
  std::unordered_set<int> method_starts_;
  std::unordered_set<int> interface_selectors_;  // Selector offsets of is-interface stubs.
  std::vector<int> roots_;
  std::vector<Context*> contexts_;
  std::unordered_set<int> primitives_used_;
  std::unordered_set<int> unique_warnings_;
  int global_max_height_ = 0;
  int run_depth_ = 0;

  bool check_method_entries();
  void print_primitives();

  // --- diagnostics ---------------------------------------------------------

  void error(MethodRun* run, int bci, const char* format, ...) __attribute__((format(printf, 4, 5)));
  void warning(MethodRun* run, int bci, const char* format, ...) __attribute__((format(printf, 4, 5)));
  std::string location(MethodRun* run, int bci);

  // --- program-level helpers -----------------------------------------------

  bool is_valid_method_id(int id) const {
    return id >= 0 && id + METHOD_HEADER_SIZE <= bytecodes_length_;  // Interface stubs have no code.
  }
  Method method_at(int id) const { return Method(bytecodes_ + id); }
  MethodInfo& info(int id) { return infos_[id]; }
  int class_tag(int class_id) const {
    return Program::class_tag_from_class_bits(program_->class_bits[class_id]);
  }
  int instance_fields(int class_id) const {
    if (class_id < 0 || class_id >= class_count_) return -1;
    int tag = class_tag(class_id);
    if (tag != INSTANCE_TAG && tag != TASK_TAG) return -1;
    return Instance::fields_from_size(Program::instance_size_from_class_bits(program_->class_bits[class_id]));
  }
  bool range_for_check_index(int index, int* start, int* end) const {
    if (index < 0 || 2 * index + 1 >= program_->class_check_ids.length()) return false;
    *start = program_->class_check_ids[2 * index];
    *end = Utils::min(static_cast<int>(program_->class_check_ids[2 * index + 1]), class_count_);
    return true;
  }
  bool is_virtual_only(int method_id) {
    MethodInfo& i = info(method_id);
    return method_at(method_id).selector_offset() >= 0 && !i.static_target && !i.receiver_classes.empty();
  }
  // Statically resolved instance methods encode a class-check index in the header.
  static int receiver_check_index(Method method) {
    int offset = method.selector_offset();
    if (offset < -1) return -2 - offset;
    return -1;
  }

  bool check_tables();
  bool check_object(Object* object, const char* what, int index);
  void collect_dispatch_info();
  void add_root(int method_id, const char* why);
  bool mark_static_target(int method_id);
  bool require_block_param(MethodRun* run, int method_id, int index);
  bool selector_arity_ok(MethodRun* run, int bci, int selector, int arity, uint64* mask);
  bool check_selector_bounds(MethodRun* run, int bci, int selector);

  // --- per-method verification ---------------------------------------------

  void verify_method(int method_id, Context* context);
  State initial_state(int method_id, Context* context);
  bool add_entry(MethodRun* run, int bci, const State& state, int from_bci);
  bool step(MethodRun* run, State* state, int bci, int* next);
  bool process_worklist(MethodRun* run);

  // Stack helpers; all report errors and return false on failure.
  bool push(MethodRun* run, State* state, Slot slot);
  bool pop(MethodRun* run, State* state, int bci, Slot* out = null);
  bool pop_n(MethodRun* run, State* state, int bci, int n);
  bool read_slot(MethodRun* run, State* state, int bci, int index, Slot* out);
  bool write_slot(MethodRun* run, State* state, int bci, int index, Slot value);
  bool block_store_ok(MethodRun* target_run, State* target_state, int target_index, Slot value);
  bool require_block(MethodRun* run, State* state, int bci, Slot slot, const char* what, Context** context);
  bool outer_read(MethodRun* run, int bci, Context* context, int index, Slot* out);
  bool outer_write(MethodRun* run, int bci, Context* context, int index, Slot value);
  bool check_field_receiver(MethodRun* run, int bci, Slot receiver, int field_index, bool is_store);
  bool check_call_args(MethodRun* run, State* state, int bci, int callee, int arity, uint64 mask);
  bool check_receiver_range(MethodRun* run, int bci, Slot receiver, int check_index, const char* what);
  bool classes_in_range(const std::vector<int>& classes, int start, int end);
  bool check_try_shape(MethodRun* run, State* state, int bci);
  bool decode(MethodRun* run, int bci, int* opcode, int* length);

  static Slot copy_for_load(Slot slot) {
    // Loading a method-id or link slot yields a plain smi.
    if (slot.kind == K_METHOD_ID || slot.is_link()) return Slot::any();
    return slot;
  }
  static Slot capture(Slot slot) {
    // Expression-stack slots captured by a block context only keep the
    // kinds that cannot be overwritten while a nested block relies on them
    // (method ids and block references become "captured" when a nested
    // block uses them); everything else is demoted so later stores in the
    // outer frame cannot invalidate what the block assumes.
    if (slot.kind == K_METHOD_ID || slot.kind == K_BLOCK || slot.kind == K_PARAM || slot.is_link()) return slot;
    return Slot::any();
  }
  static Slot capture_param(Slot slot) {
    // Parameters keep their declared kinds (which the verifier keeps
    // immutable) and their provenance; checked ranges are dropped because
    // the outer frame may overwrite such parameters.
    if (slot.kind == K_THIS || slot.kind == K_RANGE || slot.kind == K_BLOCK || slot.kind == K_PARAM) return slot;
    return Slot::any();
  }
};

// ----------------------------------------------------------------------------
// Diagnostics.

std::string VerifierImpl::location(MethodRun* run, int bci) {
  char buffer[128];
  if (run == null) {
    snprintf(buffer, sizeof(buffer), "[bci %d]", bci);
  } else {
    const char* kind = run->method.is_block_method() ? "block"
        : run->method.is_lambda_method() ? "lambda"
        : run->method.is_field_accessor() ? "accessor" : "method";
    int opcode = (bci >= 0 && bci < bytecodes_length_) ? bytecodes_[bci] : -1;
    const char* name = (opcode >= 0 && opcode < ILLEGAL_END) ? kOpcodeName[opcode] : "?";
    snprintf(buffer, sizeof(buffer), "[%s %d @ bci %d (+%d) %s]",
             kind, run->method_id, bci, bci - run->entry_bci, name);
  }
  return std::string(buffer);
}

void VerifierImpl::error(MethodRun* run, int bci, const char* format, ...) {
  if (run) run->had_error = true;
  char buffer[512];
  va_list args;
  va_start(args, format);
  vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);
  errors_.push_back(location(run, bci) + " " + buffer);
}

void VerifierImpl::warning(MethodRun* run, int bci, const char* format, ...) {
  if (!unique_warnings_.insert(bci).second) return;
  char buffer[512];
  va_list args;
  va_start(args, format);
  vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);
  warnings_.push_back(location(run, bci) + " " + buffer);
}

// ----------------------------------------------------------------------------
// Phase 0: program tables.

bool VerifierImpl::check_object(Object* object, const char* what, int index) {
  if (is_smi(object)) return true;
  if (!is_heap_object(object)) {
    error(null, -1, "%s %d is neither smi nor heap object", what, index);
    return false;
  }
  HeapObject* heap_object = HeapObject::cast(object);
  int class_id = Smi::value(heap_object->class_id());
  if (class_id < 0 || class_id >= class_count_) {
    error(null, -1, "%s %d has invalid class id %d", what, index, class_id);
    return false;
  }
  if (heap_object->class_tag() != class_tag(class_id)) {
    error(null, -1, "%s %d has class tag %d but class %d has tag %d",
          what, index, heap_object->class_tag(), class_id, class_tag(class_id));
    return false;
  }
  if (heap_walked_ && !is_heap_reference(object)) {
    error(null, -1, "%s %d does not refer to an object of the program heap", what, index);
    return false;
  }
  return true;
}

// Every builtin class id must be a valid class with the tag the VM assumes
// for it (the interpreter and the primitives use them without checks).
bool VerifierImpl::check_builtin_classes() {
  bool ok = true;
  struct { const char* name; Smi* id; int tag; } builtins[] = {
    { "string", program_->string_class_id(), STRING_TAG },
    { "array", program_->array_class_id(), ARRAY_TAG },
    { "byte_array", program_->byte_array_class_id(), BYTE_ARRAY_TAG },
    { "byte_array_cow", program_->byte_array_cow_class_id(), INSTANCE_TAG },
    { "byte_array_slice", program_->byte_array_slice_class_id(), INSTANCE_TAG },
    { "string_slice", program_->string_slice_class_id(), INSTANCE_TAG },
    { "string_byte_slice", program_->string_byte_slice_class_id(), INSTANCE_TAG },
    { "list", program_->list_class_id(), INSTANCE_TAG },
    { "list_slice", program_->list_slice_class_id(), INSTANCE_TAG },
    { "map", program_->map_class_id(), INSTANCE_TAG },
    { "tombstone", program_->tombstone_class_id(), INSTANCE_TAG },
    { "stack", program_->stack_class_id(), STACK_TAG },
    { "null", program_->null_class_id(), ODDBALL_TAG },
    { "true", program_->true_class_id(), ODDBALL_TAG },
    { "false", program_->false_class_id(), ODDBALL_TAG },
    { "object", program_->object_class_id(), INSTANCE_TAG },
    { "double", program_->double_class_id(), DOUBLE_TAG },
    { "large_integer", program_->large_integer_class_id(), LARGE_INTEGER_TAG },
    { "smi", program_->smi_class_id(), INSTANCE_TAG },
    { "task", program_->task_class_id(), TASK_TAG },
    { "large_array", program_->large_array_class_id(), INSTANCE_TAG },
    { "lazy_initializer", program_->lazy_initializer_class_id(), INSTANCE_TAG },
    { "exception", program_->exception_class_id(), INSTANCE_TAG },
  };
  for (auto& b : builtins) {
    if (!is_smi(b.id)) { error(null, -1, "builtin class id %s is not a smi", b.name); ok = false; continue; }
    int id = Smi::value(b.id);
    if (id < 0 || id >= class_count_) {
      error(null, -1, "builtin class id %s (%d) out of range", b.name, id);
      ok = false;
    } else if (class_tag(id) != b.tag) {
      error(null, -1, "builtin class %s (%d) has tag %d, expected %d", b.name, id, class_tag(id), b.tag);
      ok = false;
    }
  }
  if (!ok) return false;
  // Field layouts the VM relies on (the interpreter and the primitives read
  // these fields without checking the class size).
  struct { const char* name; Smi* id; int fields; } layouts[] = {
    { "exception", program_->exception_class_id(), 2 },
    { "lazy_initializer", program_->lazy_initializer_class_id(), 1 },
    { "map", program_->map_class_id(), Instance::MAP_BACKING_INDEX + 1 },
    { "list", program_->list_class_id(), Instance::LIST_SIZE_INDEX + 1 },
    { "list_slice", program_->list_slice_class_id(), Instance::LIST_SLICE_TO_INDEX + 1 },
    { "byte_array_cow", program_->byte_array_cow_class_id(), Instance::BYTE_ARRAY_COW_IS_MUTABLE_INDEX + 1 },
    { "byte_array_slice", program_->byte_array_slice_class_id(), Instance::BYTE_ARRAY_SLICE_TO_INDEX + 1 },
    { "large_array", program_->large_array_class_id(), Instance::LARGE_ARRAY_VECTOR_INDEX + 1 },
    { "string_slice", program_->string_slice_class_id(), Instance::STRING_SLICE_TO_INDEX + 1 },
    { "string_byte_slice", program_->string_byte_slice_class_id(), Instance::STRING_BYTE_SLICE_TO_INDEX + 1 },
    { "tombstone", program_->tombstone_class_id(), Instance::TOMBSTONE_DISTANCE_INDEX + 1 },
  };
  for (auto& layout : layouts) {
    if (instance_fields(Smi::value(layout.id)) < layout.fields) {
      error(null, -1, "builtin class %s needs at least %d fields", layout.name, layout.fields);
      ok = false;
    }
  }
  // Roots.
  auto check_oddball = [&](Object* object, Smi* class_id, const char* name) {
    if (!is_heap_object(object) || HeapObject::cast(object)->class_id() != class_id ||
        HeapObject::cast(object)->class_tag() != ODDBALL_TAG) {
      error(null, -1, "root %s is not the oddball of its class", name);
      ok = false;
    }
  };
  check_oddball(program_->null_object(), program_->null_class_id(), "null");
  check_oddball(program_->true_object(), program_->true_class_id(), "true");
  check_oddball(program_->false_object(), program_->false_class_id(), "false");
  if (!is_array(program_->empty_array()) || Array::cast(program_->empty_array())->length() != 0) {
    error(null, -1, "root empty_array is not an empty array"); ok = false;
  }
  if (!is_instance(program_->out_of_memory_error()) ||
      Instance::cast(program_->out_of_memory_error())->class_id() != program_->exception_class_id()) {
    error(null, -1, "root out_of_memory_error is not an exception"); ok = false;
  }
  for (int i = Program::app_sdk_version_INDEX; i < Program::ROOT_COUNT; i++) {
    if (!is_string(program_->root(i))) { error(null, -1, "root %d is not a string", i); ok = false; }
  }
  for (int i = 0; i < Program::ROOT_COUNT; i++) {
    if (!is_heap_reference(program_->root(i))) { error(null, -1, "root %d is not a program heap object", i); ok = false; }
  }
  return ok;
}

// Walks every object of the program heap: headers, class ids, tags and
// sizes must be consistent with the class table, variable-sized objects
// must fit their block, external data must lie inside the image, and
// every pointer field must refer to a walked object.
bool VerifierImpl::walk_heap() {
  image_begin_ = reinterpret_cast<uword>(program_);
  image_end_ = image_begin_ + program_->size();
  std::vector<uword> objects;
  ProgramBlockList& blocks = program_->heap_.blocks_;
  for (auto it = blocks.begin(); it != blocks.end(); ++it) {
    ProgramBlock* block = *it;
    uword p = reinterpret_cast<uword>(block->base());
    uword top = reinterpret_cast<uword>(block->top());
    if (p < image_begin_ || top > image_end_ || p > top) {
      error(null, -1, "program heap block outside of the image");
      return false;
    }
    while (p < top) {
      uword remaining = top - p;
      if (remaining < static_cast<uword>(2 * WORD_SIZE)) { error(null, -1, "truncated heap object at %#zx", p); return false; }
      HeapObject* object = HeapObject::from_address(p);
      if (!is_smi(object->header())) { error(null, -1, "heap object at %#zx has a non-smi header", p); return false; }
      int class_id = Smi::value(object->class_id());
      if (class_id < 0 || class_id >= class_count_) { error(null, -1, "heap object at %#zx has class id %d", p, class_id); return false; }
      int tag = object->class_tag();
      if (tag != class_tag(class_id)) {
        error(null, -1, "heap object at %#zx has tag %d but class %d has tag %d", p, tag, class_id, class_tag(class_id));
        return false;
      }
      word declared = Program::instance_size_from_class_bits(program_->class_bits[class_id]);
      word size = 0;
      switch (tag) {
        case INSTANCE_TAG:
        case ODDBALL_TAG:
          size = declared;
          if (size < HeapObject::SIZE) { error(null, -1, "class %d has instance size %zd", class_id, size); return false; }
          if (tag == INSTANCE_TAG) heap_instances_.push_back(object);
          break;
        case ARRAY_TAG: {
          word length = Array::cast(object)->length();
          if (length < 0 || static_cast<uword>(length) > remaining / WORD_SIZE) { error(null, -1, "array at %#zx has length %zd", p, length); return false; }
          size = Array::allocation_size(length);
          break;
        }
        case BYTE_ARRAY_TAG: {
          ByteArray* array = ByteArray::cast(object);
          if (array->has_external_address()) {
            size = ByteArray::external_allocation_size();
            if (static_cast<uword>(size) > remaining) { error(null, -1, "truncated external byte array at %#zx", p); return false; }
            ByteArray::Bytes bytes(array);
            uword a = reinterpret_cast<uword>(bytes.address());
            if (bytes.length() < 0 || a < image_begin_ || a + bytes.length() > image_end_) {
              error(null, -1, "external byte array at %#zx points outside of the image", p); return false;
            }
          } else {
            word length = ByteArray::Bytes(array).length();
            if (static_cast<uword>(length) > remaining) { error(null, -1, "byte array at %#zx has length %zd", p, length); return false; }
            size = ByteArray::internal_allocation_size(length);
          }
          break;
        }
        case STRING_TAG: {
          String* string = String::cast(object);
          if (!string->content_on_heap()) {
            size = String::external_allocation_size();
            if (static_cast<uword>(size) > remaining) { error(null, -1, "truncated external string at %#zx", p); return false; }
            String::Bytes bytes(string);
            uword a = reinterpret_cast<uword>(bytes.address());
            if (bytes.length() < 0 || a < image_begin_ || a + bytes.length() > image_end_) {
              error(null, -1, "external string at %#zx points outside of the image", p); return false;
            }
          } else {
            word length = string->length();
            if (length < 0 || static_cast<uword>(length) > remaining) { error(null, -1, "string at %#zx has length %zd", p, length); return false; }
            size = String::internal_allocation_size(length);
          }
          break;
        }
        case DOUBLE_TAG: size = Double::allocation_size(); break;
        case LARGE_INTEGER_TAG: size = LargeInteger::allocation_size(); break;
        default:
          error(null, -1, "heap object at %#zx has tag %d which is not allowed in a program heap", p, tag);
          return false;
      }
      if (declared != 0 && declared != size) { error(null, -1, "heap object at %#zx: size %zd does not match class size %zd", p, size, declared); return false; }
      if (size <= 0 || !Utils::is_aligned(size, WORD_SIZE) || static_cast<uword>(size) > remaining) {
        error(null, -1, "heap object at %#zx has invalid size %zd", p, size);
        return false;
      }
      heap_objects_.insert(p);
      objects.push_back(p);
      stats_->heap_bytes += size;
      p += size;
    }
    if (p != top) { error(null, -1, "program heap block does not end on an object boundary"); return false; }
  }
  heap_walked_ = true;
  stats_->heap_objects = static_cast<int>(objects.size());
  // Second pass: every pointer field refers to a walked object.
  for (uword p : objects) {
    HeapObject* object = HeapObject::from_address(p);
    int tag = object->class_tag();
    if (tag == ARRAY_TAG) {
      Array* array = Array::cast(object);
      for (word i = 0; i < array->length(); i++) {
        stats_->heap_references++;
        if (!is_heap_reference(array->at(i))) { error(null, -1, "array at %#zx element %zd is not a heap reference", p, i); return false; }
      }
    } else if (tag == INSTANCE_TAG) {
      Instance* instance = Instance::cast(object);
      int fields = instance_fields(Smi::value(instance->class_id()));
      for (int i = 0; i < fields; i++) {
        stats_->heap_references++;
        if (!is_heap_reference(instance->at(i))) { error(null, -1, "instance at %#zx field %d is not a heap reference", p, i); return false; }
      }
    }
  }
  return true;
}

// Instances whose fields the interpreter turns into method ids: lambdas
// (receivers of methods that use INVOKE_LAMBDA_TAIL) and lazy initializers.
bool VerifierImpl::check_heap_method_ids() {
  bool ok = true;
  Smi* lazy = program_->lazy_initializer_class_id();
  for (HeapObject* object : heap_instances_) {
    Instance* instance = Instance::cast(object);
    int class_id = Smi::value(instance->class_id());
    if (lambda_classes_.count(class_id) != 0) {
      Object* id_object = instance_fields(class_id) >= 2 ? instance->at(0) : null;
      int id = (id_object != null && is_smi(id_object)) ? Smi::value(id_object) : -1;
      if (!is_valid_method_id(id) || !method_at(id).is_lambda_method()) {
        error(null, -1, "lambda instance in the program heap has invalid method id %d", id);
        ok = false;
      }
    } else if (instance->class_id() == lazy) {
      Object* id_object = instance->at(0);
      int id = is_smi(id_object) ? Smi::value(id_object) : -1;
      if (!is_valid_method_id(id) || !method_at(id).is_normal_method() || method_at(id).arity() != 0) {
        error(null, -1, "lazy initializer in the program heap has invalid method id %d", id);
        ok = false;
      }
    }
  }
  return ok;
}

bool VerifierImpl::check_tables() {
  bool ok = true;
  if (bytecodes_length_ <= 0) { error(null, -1, "no bytecodes"); return false; }
  if (class_count_ <= 0) { error(null, -1, "no classes"); return false; }
  if (!walk_heap()) return false;
  if (!check_builtin_classes()) return false;

  // Dispatch table: every entry is -1 or a valid method id.
  for (int i = 0; i < dispatch_length_; i++) {
    int id = program_->dispatch_table[i];
    if (id == -1) continue;
    if (!is_valid_method_id(id)) {
      error(null, -1, "dispatch table entry %d has invalid method id %d", i, id);
      ok = false;
    }
  }

  // Class check ids come in (start, end) pairs.
  if ((program_->class_check_ids.length() & 1) != 0) {
    error(null, -1, "class_check_ids has odd length %d", static_cast<int>(program_->class_check_ids.length()));
    ok = false;
  }
  for (int i = 0; i + 1 < program_->class_check_ids.length(); i += 2) {
    int start = program_->class_check_ids[i];
    int end = program_->class_check_ids[i + 1];
    if (start > end) {
      error(null, -1, "class check %d has start %d > end %d", i / 2, start, end);
      ok = false;
    }
  }

  // Interface check offsets are selector offsets used by find_method; the
  // dispatch table index class_id + offset must exist for every class.
  for (int i = 0; i < program_->interface_check_offsets.length(); i++) {
    int offset = program_->interface_check_offsets[i];
    if (!check_selector_bounds(null, -1, offset)) ok = false;
  }
  // Operator selectors that were tree-shaken away have offset -1; the
  // corresponding bytecodes must then not occur (checked per site).
  for (int op = INVOKE_EQ; op <= INVOKE_SIZE; op++) {
    int offset = program_->invoke_bytecode_offset(static_cast<Opcode>(op));
    if (offset != -1 && !check_selector_bounds(null, -1, offset)) {
      error(null, -1, "invoke bytecode offset for %s is invalid (%d)", kOpcodeName[op], offset);
      ok = false;
    }
  }

  // Entry points.
#define CHECK_ENTRY_POINT(name, lib_name, ep_arity)                                          \
  { int dispatch_index = program_->entry_point_indexes_[Program::name##_INDEX];              \
    if (dispatch_index == -1 && Program::name##_INDEX == Program::entry_spawn_INDEX) {      \
      /* Tree-shaken spawn entry point; the VM checks has_entry_spawn. */                    \
    } else if (dispatch_index < 0 || dispatch_index >= dispatch_length_ ||                   \
        !is_valid_method_id(program_->dispatch_table[dispatch_index])) {                     \
      error(null, -1, "entry point %s has invalid dispatch index %d", lib_name, dispatch_index); \
      ok = false;                                                                            \
    } else {                                                                                 \
      int id = program_->dispatch_table[dispatch_index];                                     \
      Method m = method_at(id);                                                              \
      if (m.arity() != ep_arity) {                                                           \
        error(null, -1, "entry point %s has arity %d, expected %d", lib_name, m.arity(), ep_arity); \
        ok = false;                                                                          \
      }                                                                                      \
      info(id).entry_point = true;                                                           \
      mark_static_target(id);                                                                \
      add_root(id, "entry point");                                                           \
    }                                                                                        \
  }
  ENTRY_POINTS(CHECK_ENTRY_POINT)
#undef CHECK_ENTRY_POINT

  // Literals and globals must be well-formed objects. Lazy initializers in
  // globals carry a method id that INVOKE_INITIALIZER_TAIL jumps to.
  for (int i = 0; i < program_->literals.length(); i++) {
    if (!check_object(program_->literals.at(i), "literal", i)) ok = false;
  }
  for (int i = 0; i < program_->global_variables.length(); i++) {
    Object* value = program_->global_variables.at(i);
    if (!check_object(value, "global", i)) { ok = false; continue; }
    if (is_instance(value)) {
      Instance* instance = Instance::cast(value);
      if (instance->class_id() == program_->lazy_initializer_class_id()) {
        if (instance_fields(Smi::value(instance->class_id())) < 1) {
          error(null, -1, "lazy initializer class has no fields");
          ok = false;
          continue;
        }
        Object* id_object = instance->at(0);
        int id = is_smi(id_object) ? Smi::value(id_object) : -1;
        if (!is_valid_method_id(id) || method_at(id).arity() != 0 || !method_at(id).is_normal_method()) {
          error(null, -1, "global %d has lazy initializer with invalid method id %d", i, id);
          ok = false;
        } else {
          mark_static_target(id);
          add_root(id, "lazy initializer");
        }
      }
    }
  }
  return ok;
}

bool VerifierImpl::check_selector_bounds(MethodRun* run, int bci, int selector) {
  // find_method indexes dispatch_table[class_id + selector] for any class id.
  if (selector < 0 || selector + class_count_ - 1 >= dispatch_length_) {
    error(run, bci, "selector offset %d + %d classes exceeds dispatch table length %d",
          selector, class_count_, dispatch_length_);
    return false;
  }
  return true;
}

void VerifierImpl::collect_dispatch_info() {
  for (int i = 0; i < program_->interface_check_offsets.length(); i++) {
    interface_selectors_.insert(program_->interface_check_offsets[i]);
  }
  for (int i = 0; i < dispatch_length_; i++) {
    int id = program_->dispatch_table[i];
    if (id == -1 || !is_valid_method_id(id)) continue;
    Method method = method_at(id);
    MethodInfo& mi = info(id);
    int selector = method.selector_offset();
    // Interface-check stubs have no bytecodes at all; they are only looked
    // up by IS_INTERFACE / AS_INTERFACE and must never be invoked.
    if (selector >= 0 && interface_selectors_.count(selector) != 0) continue;
    if (selector >= 0) {
      int class_id = i - selector;
      if (class_id >= 0 && class_id < class_count_) {
        mi.receiver_classes.push_back(class_id);
        std::vector<int>& targets = selector_targets_[selector];
        if (std::find(targets.begin(), targets.end(), id) == targets.end()) targets.push_back(id);
      }
    }
    add_root(id, "dispatch table");
  }
}

void VerifierImpl::add_root(int method_id, const char* why) {
  if (method_starts_.insert(method_id).second) {
    roots_.push_back(method_id);
    if (verbosity_ >= 3) fprintf(stderr, "verifier: root %d (%s)\n", method_id, why);
  }
}

bool VerifierImpl::mark_static_target(int method_id) {
  MethodInfo& mi = info(method_id);
  if (mi.static_target) return false;
  mi.static_target = true;
  changed_ = true;
  return true;
}

// Records that parameter 'index' of 'method_id' must be a block. Returns
// true if this is new information (the fixpoint loop will run again).
bool VerifierImpl::require_block_param(MethodRun* run, int method_id, int index) {
  if (index < 0 || index >= 64) {
    error(run, -1, "cannot track block parameter %d of method %d", index, method_id);
    return false;
  }
  MethodInfo& mi = info(method_id);
  uint64 bit = static_cast<uint64>(1) << index;
  if ((mi.required_mask & bit) != 0) return false;
  mi.required_mask |= bit;
  changed_ = true;
  return true;
}

// Checks that all virtual targets of the selector have the given arity and
// computes the union of their block-parameter masks.
bool VerifierImpl::selector_arity_ok(MethodRun* run, int bci, int selector, int arity, uint64* mask) {
  *mask = 0;
  if (!check_selector_bounds(run, bci, selector)) return false;
  if (interface_selectors_.count(selector) != 0) {
    error(run, bci, "virtual call with the selector of an interface-check stub (%d)", selector);
    return false;
  }
  auto probe = selector_targets_.find(selector);
  if (probe == selector_targets_.end()) return true;  // Only lookup failures.
  for (int id : probe->second) {
    Method target = method_at(id);
    if (target.arity() != arity) {
      error(run, bci, "virtual call with %d arguments can reach method %d with arity %d",
            arity, id, target.arity());
      return false;
    }
    *mask |= info(id).required_mask;
  }
  return true;
}

// ----------------------------------------------------------------------------
// Per-method verification.

State VerifierImpl::initial_state(int method_id, Context* context) {
  Method method = method_at(method_id);
  State state;
  int arity = method.arity();
  state.params.resize(arity);
  MethodInfo& mi = info(method_id);
  for (int n = 0; n < arity; n++) {
    state.params[n] = Slot::make(K_PARAM, (static_cast<uint32>(method_id) << 8) | n);
  }
  if (context != null) {
    state.params[0] = Slot::make(K_BLOCK, context->id);
    for (int n = 1; n < arity; n++) state.params[n] = Slot::any();  // Blocks cannot take blocks.
  } else {
    for (int n = 0; n < arity && n < 64; n++) {
      if ((mi.required_mask >> n) & 1) state.params[n] = Slot::make(K_BLOCK, 0);
    }
    if (arity > 0 && !method.is_lambda_method()) {
      int check_index = receiver_check_index(method);
      if (check_index >= 0) {
        state.params[0] = Slot::make(K_RANGE, check_index);
      } else if (is_virtual_only(method_id)) {
        state.params[0] = Slot::make(K_THIS, method_id);
      }
    }
  }
  return state;
}

bool VerifierImpl::decode(MethodRun* run, int bci, int* opcode, int* length) {
  if (bci < 0 || bci >= bytecodes_length_) {
    error(run, bci, "bci outside of bytecodes");
    return false;
  }
  int op = bytecodes_[bci];
  if (op >= ILLEGAL_END) {
    error(run, bci, "invalid opcode %d", op);
    return false;
  }
  int len = kOpcodeLength[op];
  if (bci + len > bytecodes_length_) {
    error(run, bci, "instruction %s runs past the end of the bytecodes", kOpcodeName[op]);
    return false;
  }
  *opcode = op;
  *length = len;
  return true;
}

bool VerifierImpl::add_entry(MethodRun* run, int bci, const State& state, int from_bci) {
  if (bci < 0 || bci >= bytecodes_length_) {
    error(run, from_bci, "branch target %d outside of bytecodes", bci);
    return false;
  }
  auto probe = run->entries.find(bci);
  if (probe == run->entries.end()) {
    run->entries.emplace(bci, state);
    run->worklist.push_back(bci);
    return true;
  }
  State& old = probe->second;
  if (old.same(state)) return true;
  if (old.height() != state.height() || old.arity() != state.arity()) {
    error(run, from_bci, "stack mismatch at merge into bci %d: height %d vs %d", bci,
          state.height(), old.height());
    return false;
  }
  // Join slot by slot. Kinds that carry proof obligations (block, method
  // id, link slots) must agree exactly; the others join to ANY.
  bool widened = false;
  for (int part = 0; part < 2; part++) {
    std::vector<Slot>& old_slots = part == 0 ? old.stack : old.params;
    const std::vector<Slot>& new_slots = part == 0 ? state.stack : state.params;
    for (size_t i = 0; i < old_slots.size(); i++) {
      Slot& o = old_slots[i];
      const Slot& n = new_slots[i];
      if (n.captured && !o.captured) { o.captured = 1; widened = true; }
      if (o.same(n)) continue;
      bool exact = o.is_immutable() || n.is_immutable() || o.kind == K_BLOCK || n.kind == K_BLOCK;
      if (exact) {
        error(run, from_bci, "stack mismatch at merge into bci %d: %s %d is %s/%u vs %s/%u", bci,
              part == 0 ? "slot" : "param", static_cast<int>(i),
              kind_name(n.kind), n.aux, kind_name(o.kind), o.aux);
        return false;
      }
      o = Slot::any();
      widened = true;
    }
  }
  if (widened) run->worklist.push_back(bci);  // Re-verify from the widened state.
  return true;
}

bool VerifierImpl::push(MethodRun* run, State* state, Slot slot) {
  state->stack.push_back(slot);
  if (state->height() > run->max_height) run->max_height = state->height();
  return true;
}

bool VerifierImpl::pop(MethodRun* run, State* state, int bci, Slot* out) {
  if (state->stack.empty()) {
    error(run, bci, "pop from empty expression stack");
    return false;
  }
  if (out) *out = state->stack.back();
  state->stack.pop_back();
  return true;
}

bool VerifierImpl::pop_n(MethodRun* run, State* state, int bci, int n) {
  if (n < 0 || n > state->height()) {
    error(run, bci, "pop %d with stack height %d", n, state->height());
    return false;
  }
  state->stack.resize(state->height() - n);
  return true;
}

bool VerifierImpl::read_slot(MethodRun* run, State* state, int bci, int index, Slot* out) {
  bool frame;
  Slot* slot = state->at(index, &frame);
  if (slot == null) {
    error(run, bci, "load of %s slot S%d (height %d, arity %d)",
          frame ? "frame" : "out-of-frame", index, state->height(), state->arity());
    return false;
  }
  *out = copy_for_load(*slot);
  return true;
}

bool VerifierImpl::write_slot(MethodRun* run, State* state, int bci, int index, Slot value) {
  bool frame;
  Slot* slot = state->at(index, &frame);
  if (slot == null) {
    error(run, bci, "store to %s slot S%d (height %d, arity %d)",
          frame ? "frame" : "out-of-frame", index, state->height(), state->arity());
    return false;
  }
  if (slot->kind == K_METHOD_ID) {
    // The compiler reuses the slot once the block is dead. That is fine as
    // long as no block reference to it is live and no nested block loads it.
    bool live = slot->captured != 0;
    for (const Slot& s : state->stack) if (s.kind == K_BLOCK && s.aux == slot->aux) live = true;
    for (const Slot& s : state->params) if (s.kind == K_BLOCK && s.aux == slot->aux) live = true;
    if (live) {
      error(run, bci, "store to method-id slot S%d while its block is live", index);
      return false;
    }
  } else if (slot->is_immutable()) {
    error(run, bci, "store to immutable %s slot S%d", kind_name(slot->kind), index);
    return false;
  } else if (slot->kind == K_BLOCK && slot->captured) {
    error(run, bci, "store to block slot S%d used by a nested block", index);
    return false;
  }
  bool is_param = index >= state->height() + FRAME_SIZE;
  if (is_param && (slot->kind == K_THIS || slot->kind == K_RANGE || slot->kind == K_BLOCK)) {
    // Parameters captured by blocks keep their declared kind, so typed
    // parameters (this, block, declared range) must not be overwritten.
    error(run, bci, "store to %s parameter slot S%d", kind_name(slot->kind), index);
    return false;
  }
  if (value.kind == K_BLOCK && !block_store_ok(run, state, index, value)) {
    error(run, bci, "block reference stored below its method-id slot S%d", index);
    return false;
  }
  *slot = copy_for_load(value);
  return true;
}

// A block reference must never end up in a slot that outlives the
// method-id slot it points to: the target frame must be the frame of the
// method id (and the target slot above it) or a younger (nested) frame.
bool VerifierImpl::block_store_ok(MethodRun* target_run, State* target_state, int target_index, Slot value) {
  if (value.aux == 0) return true;  // Opaque block (a parameter); its frame is older than anything here.
  Context* c = contexts_[value.aux];
  if (c->owner->depth > target_run->depth) return false;
  if (c->owner != target_run) return true;
  int h = target_state->height();
  if (target_index >= h) return false;  // A parameter slot is below all expression slots.
  int target_bottom = h - 1 - target_index;
  for (int i = 0; i < h; i++) {
    if (target_state->stack[i].kind == K_METHOD_ID && target_state->stack[i].aux == value.aux) {
      return target_bottom > i;
    }
  }
  return false;
}

bool VerifierImpl::require_block(MethodRun* run, State* state, int bci, Slot slot, const char* what, Context** context) {
  *context = null;
  if (slot.kind == K_BLOCK) {
    if (slot.aux != 0) *context = contexts_[slot.aux];
    return true;
  }
  if (slot.kind == K_PARAM) {
    // An untouched parameter is used as a block: record the requirement
    // and abort this run; the next pass verifies with the parameter as block.
    int owner = slot.aux >> 8;
    int index = slot.aux & 0xff;
    if (require_block_param(run, owner, index)) {
      run->aborted = true;
      return false;
    }
  }
  error(run, bci, "%s requires a block but found %s", what, kind_name(slot.kind));
  return false;
}

bool VerifierImpl::outer_read(MethodRun* run, int bci, Context* context, int index, Slot* out) {
  if (context == null) {
    error(run, bci, "outer access through opaque block reference");
    return false;
  }
  bool frame;
  Slot* slot = context->state.at(index, &frame);
  if (slot == null) {
    error(run, bci, "outer load of %s slot %d (outer height %d, outer arity %d)",
          frame ? "frame" : "out-of-frame", index, context->state.height(), context->state.arity());
    return false;
  }
  if (slot->kind == K_BLOCK) context->block_accesses.push_back(index);
  *out = copy_for_load(*slot);
  return true;
}

bool VerifierImpl::outer_write(MethodRun* run, int bci, Context* context, int index, Slot value) {
  if (context == null) {
    error(run, bci, "outer store through opaque block reference");
    return false;
  }
  bool frame;
  Slot* slot = context->state.at(index, &frame);
  if (slot == null) {
    error(run, bci, "outer store to %s slot %d", frame ? "frame" : "out-of-frame", index);
    return false;
  }
  if (slot->kind != K_ANY && slot->kind != K_PARAM) {
    error(run, bci, "outer store to %s slot %d", kind_name(slot->kind), index);
    return false;
  }
  if (value.kind == K_BLOCK && !block_store_ok(context->owner, &context->state, index, value)) {
    error(run, bci, "block reference stored into outer slot %d that outlives it", index);
    return false;
  }
  return true;
}

bool VerifierImpl::classes_in_range(const std::vector<int>& classes, int start, int end) {
  for (int c : classes) if (c < start || c >= end) return false;
  return !classes.empty();
}

// Checks that the receiver of a static call to a method with a declared
// receiver range is provably in that range. Unproven receivers are warnings
// (errors in strict mode).
bool VerifierImpl::check_receiver_range(MethodRun* run, int bci, Slot receiver, int check_index, const char* what) {
  int start, end;
  if (!range_for_check_index(check_index, &start, &end)) {
    error(run, bci, "%s: invalid class check index %d", what, check_index);
    return false;
  }
  bool proven = false;
  switch (receiver.kind) {
    case K_ALLOC: proven = receiver.aux >= static_cast<uint32>(start) && receiver.aux < static_cast<uint32>(end); break;
    case K_THIS: proven = classes_in_range(info(receiver.aux).receiver_classes, start, end); break;
    case K_RANGE:
    case K_CHECKED: {
      int s2, e2;
      proven = range_for_check_index(receiver.aux, &s2, &e2) && s2 >= start && e2 <= end && s2 < e2;
      break;
    }
    default: break;
  }
  if (!proven && final_pass_) {
    if (strict_) {
      error(run, bci, "%s: receiver (%s) not proven to be in class range [%d,%d)",
            what, kind_name(receiver.kind), start, end);
    } else {
      warning(run, bci, "%s: receiver (%s) not proven to be in class range [%d,%d)",
              what, kind_name(receiver.kind), start, end);
    }
  }
  return proven;
}

bool VerifierImpl::check_field_receiver(MethodRun* run, int bci, Slot receiver, int field_index, bool is_store) {
  if (!final_pass_) return true;  // Only count once, in the final pass.
  stats_->field_sites++;
  auto fields_ok = [&](int class_id) { return instance_fields(class_id) > field_index; };
  switch (receiver.kind) {
    case K_THIS: {
      const std::vector<int>& classes = info(receiver.aux).receiver_classes;
      bool ok = !classes.empty();
      for (int c : classes) if (!fields_ok(c)) ok = false;
      if (ok) { stats_->field_sites_this++; return true; }
      // The method is inherited by classes without the field (for example a
      // method of the abstract 'string' class that first checks 'this is
      // StringSlice_'). The verifier does not track branch conditions, so
      // this needs a witness (an as-check the compiler must not remove).
      break;
    }
    case K_ALLOC:
      if (fields_ok(receiver.aux)) { stats_->field_sites_alloc++; return true; }
      error(run, bci, "field %d access on allocated instance of class %u with %d fields",
            field_index, receiver.aux, instance_fields(receiver.aux));
      return false;
    case K_RANGE:
    case K_CHECKED: {
      int start, end;
      bool ok = range_for_check_index(receiver.aux, &start, &end) && start < end;
      for (int c = start; ok && c < end; c++) if (!fields_ok(c)) ok = false;
      if (ok) { stats_->field_sites_range++; return true; }
      break;  // Same as for `this`: the range is imprecise; needs a witness.
    }
    default:
      break;
  }
  stats_->field_sites_unproven++;
  if (strict_) {
    error(run, bci, "%s field %d: receiver kind %s not proven to be an instance with enough fields",
          is_store ? "store" : "load", field_index, kind_name(receiver.kind));
    return false;
  }
  warning(run, bci, "%s field %d: receiver kind %s not proven to be an instance with enough fields",
          is_store ? "store" : "load", field_index, kind_name(receiver.kind));
  return true;  // The interpreter checks field accesses of untrusted processes at run time.
}

// Checks the arguments of a call against the callee's block requirements.
// The arguments are the top 'arity' slots; parameter n is slot (height - arity + n).
bool VerifierImpl::check_call_args(MethodRun* run, State* state, int bci, int callee, int arity, uint64 mask) {
  if (arity > state->height()) {
    error(run, bci, "call with arity %d but stack height is %d", arity, state->height());
    return false;
  }
  if (mask == 0) return true;
  int base = state->height() - arity;
  for (int n = 0; n < arity && n < 64; n++) {
    if (((mask >> n) & 1) == 0) continue;
    Slot arg = state->stack[base + n];
    Context* context;
    char what[64];
    snprintf(what, sizeof(what), "argument %d of call to method %d", n, callee);
    if (!require_block(run, state, bci, arg, what, &context)) return false;
  }
  return true;
}

// try/finally must be compiled exactly as
//   LINK 0; LOAD_BLOCK k; INVOKE_BLOCK 1; POP_1; UNLINK 0
// because the unwinder assumes this frame layout (see interpreter_run.cc,
// UNWIND_IMPLEMENTATION, "Hit unwind protect").
bool VerifierImpl::check_try_shape(MethodRun* run, State* state, int bci) {
  int p = bci + LINK_LENGTH;
  if (p + LOAD_BLOCK_LENGTH + INVOKE_BLOCK_LENGTH + POP_1_LENGTH + UNLINK_LENGTH > bytecodes_length_) {
    error(run, bci, "try sequence runs past the end of the bytecodes");
    return false;
  }
  if (bytecodes_[p] != LOAD_BLOCK) { error(run, bci, "LINK not followed by LOAD_BLOCK"); return false; }
  int index = bytecodes_[p + 1];
  p += LOAD_BLOCK_LENGTH;
  if (bytecodes_[p] != INVOKE_BLOCK || bytecodes_[p + 1] != 1) {
    error(run, bci, "try block must be invoked with INVOKE_BLOCK 1");
    return false;
  }
  p += INVOKE_BLOCK_LENGTH;
  if (bytecodes_[p] != POP_1) { error(run, bci, "try call not followed by POP_1"); return false; }
  p += POP_1_LENGTH;
  if (bytecodes_[p] != UNLINK) { error(run, bci, "try sequence not followed by UNLINK"); return false; }
  // The block loaded must be a block of arity 1 of this frame (the state
  // has the four link slots pushed already, matching LOAD_BLOCK's view).
  bool frame;
  Slot* slot = state->at(index, &frame);
  if (slot == null || slot->kind != K_METHOD_ID) {
    error(run, bci, "try block slot S%d does not hold a block method id", index);
    return false;
  }
  Context* context = contexts_[slot->aux];
  if (method_at(context->block_method).arity() != 1) {
    error(run, bci, "try block must have arity 1");
    return false;
  }
  return true;
}

#define OPERAND_U8(offset) (bytecodes_[bci + (offset)])
#define OPERAND_U16(offset) (Utils::read_unaligned_uint16(bytecodes_ + bci + (offset)))
#define OPERAND_U32(offset) (Utils::read_unaligned_uint32(bytecodes_ + bci + (offset)))

// Executes one instruction abstractly. Returns false on error or abort.
// *next is set to -1 when the instruction does not fall through.
bool VerifierImpl::step(MethodRun* run, State* state, int bci, int* next) {
  int opcode, length;
  if (!decode(run, bci, &opcode, &length)) return false;
  *next = bci + length;
  if (final_pass_) {
    stats_->instructions++;
    stats_->bytes += length;
    if (coverage_ != null) {
      coverage_[bci] = 1;
      for (int i = 1; i < length; i++) coverage_[bci + i] = 2;
    }
    if (opcode == THROW && bci > 0 && bytecodes_[bci - 1] == LOAD_NULL) stats_->synthetic_terminators++;
  }
  Method method = run->method;
  Slot slot, value;
  Context* context = null;

  switch (opcode) {
    case LOAD_LOCAL:
    case LOAD_LOCAL_WIDE: {
      int index = opcode == LOAD_LOCAL ? OPERAND_U8(1) : OPERAND_U16(1);
      if (!read_slot(run, state, bci, index, &slot)) return false;
      return push(run, state, slot);
    }
    case LOAD_LOCAL_0: case LOAD_LOCAL_1: case LOAD_LOCAL_2:
    case LOAD_LOCAL_3: case LOAD_LOCAL_4: case LOAD_LOCAL_5: {
      if (!read_slot(run, state, bci, opcode - LOAD_LOCAL_0, &slot)) return false;
      return push(run, state, slot);
    }
    case POP_LOAD_LOCAL: {
      int index = OPERAND_U8(1);
      if (!pop(run, state, bci)) return false;
      if (!read_slot(run, state, bci, index, &slot)) return false;
      return push(run, state, slot);
    }
    case STORE_LOCAL: {
      int index = OPERAND_U8(1);
      if (state->height() < 1) { error(run, bci, "store from empty stack"); return false; }
      value = state->stack.back();
      if (index == 0) return true;  // Storing the top into itself.
      return write_slot(run, state, bci, index, value);
    }
    case STORE_LOCAL_POP: {
      int index = OPERAND_U8(1);
      if (!pop(run, state, bci, &value)) return false;
      return write_slot(run, state, bci, index - 1, value);
    }
    case LOAD_OUTER: {
      int index = OPERAND_U8(1);
      if (!pop(run, state, bci, &slot)) return false;
      if (!require_block(run, state, bci, slot, "LOAD_OUTER", &context)) return false;
      if (!outer_read(run, bci, context, index, &value)) return false;
      return push(run, state, value);
    }
    case STORE_OUTER: {
      int index = OPERAND_U8(1);
      if (!pop(run, state, bci, &value)) return false;
      if (!pop(run, state, bci, &slot)) return false;
      if (!require_block(run, state, bci, slot, "STORE_OUTER", &context)) return false;
      if (!outer_write(run, bci, context, index, value)) return false;
      return push(run, state, copy_for_load(value));
    }
    case LOAD_FIELD:
    case LOAD_FIELD_WIDE: {
      int index = opcode == LOAD_FIELD ? OPERAND_U8(1) : OPERAND_U16(1);
      if (!pop(run, state, bci, &slot)) return false;
      if (!check_field_receiver(run, bci, slot, index, false)) return false;
      return push(run, state, Slot::any());
    }
    case LOAD_FIELD_LOCAL:
    case POP_LOAD_FIELD_LOCAL: {
      int encoded = OPERAND_U8(1);
      int local = encoded & 0x0f;
      int field = encoded >> 4;
      if (opcode == POP_LOAD_FIELD_LOCAL && !pop(run, state, bci)) return false;
      if (!read_slot(run, state, bci, local, &slot)) return false;
      if (!check_field_receiver(run, bci, slot, field, false)) return false;
      return push(run, state, Slot::any());
    }
    case STORE_FIELD:
    case STORE_FIELD_WIDE:
    case STORE_FIELD_POP: {
      int index = opcode == STORE_FIELD_WIDE ? OPERAND_U16(1) : OPERAND_U8(1);
      if (!pop(run, state, bci, &value)) return false;
      if (!pop(run, state, bci, &slot)) return false;
      if (!check_field_receiver(run, bci, slot, index, true)) return false;
      if (opcode == STORE_FIELD_POP) return true;
      return push(run, state, copy_for_load(value));
    }
    case LOAD_LITERAL:
    case LOAD_LITERAL_WIDE: {
      int index = opcode == LOAD_LITERAL ? OPERAND_U8(1) : OPERAND_U16(1);
      if (index >= program_->literals.length()) {
        error(run, bci, "literal index %d out of bounds (%d)", index, static_cast<int>(program_->literals.length()));
        return false;
      }
      return push(run, state, Slot::any());
    }
    case LOAD_NULL: case LOAD_SMI_0: case LOAD_SMI_1:
    case LOAD_SMI_U8: case LOAD_SMI_U16: case LOAD_SMI_U32:
      return push(run, state, Slot::any());
    case LOAD_SMIS_0: {
      int count = OPERAND_U8(1);
      for (int i = 0; i < count; i++) push(run, state, Slot::any());
      return true;
    }
    case LOAD_METHOD: {
      int id = static_cast<int>(OPERAND_U32(1));
      if (!is_valid_method_id(id)) { error(run, bci, "LOAD_METHOD of invalid method id %d", id); return false; }
      Method target = method_at(id);
      if (target.is_lambda_method()) {
        mark_static_target(id);
        add_root(id, "lambda");
        return push(run, state, Slot::any());
      }
      if (!target.is_block_method()) {
        error(run, bci, "LOAD_METHOD of method %d which is neither block nor lambda", id);
        return false;
      }
      MethodInfo& bi = info(id);
      if (bi.load_site != -1 && bi.load_site != bci) {
        error(run, bci, "block %d is loaded from two sites (%d and %d)", id, bi.load_site, bci);
        return false;
      }
      bi.load_site = bci;
      method_starts_.insert(id);
      // The context is the frame layout with the token on top. A site in a
      // loop may be visited again after a merge widened the state; the
      // context is then widened as well and the block re-verified.
      Context* c;
      auto probe = run->site_contexts.find(bci);
      if (probe == run->site_contexts.end()) {
        c = new Context();
        c->id = static_cast<int>(contexts_.size());
        c->block_method = id;
        c->owner_method = run->method_id;
        c->owner_arity = method.arity();
        c->owner = run;
        contexts_.push_back(c);
        run->site_contexts[bci] = c;
      } else {
        c = probe->second;
      }
      push(run, state, Slot::make(K_METHOD_ID, c->id));
      State captured;
      captured.params.reserve(state->params.size());
      for (const Slot& s : state->params) captured.params.push_back(capture_param(s));
      captured.stack.reserve(state->stack.size());
      for (const Slot& s : state->stack) captured.stack.push_back(capture(s));
      if (probe == run->site_contexts.end()) {
        c->state = captured;
      } else {
        for (int part = 0; part < 2; part++) {
          std::vector<Slot>& old_slots = part == 0 ? c->state.stack : c->state.params;
          const std::vector<Slot>& new_slots = part == 0 ? captured.stack : captured.params;
          if (old_slots.size() != new_slots.size()) { error(run, bci, "context shape changed"); return false; }
          for (size_t i = 0; i < old_slots.size(); i++) {
            if (old_slots[i].same(new_slots[i])) continue;
            if (old_slots[i].is_immutable() || new_slots[i].is_immutable() ||
                old_slots[i].kind == K_BLOCK || new_slots[i].kind == K_BLOCK) {
              error(run, bci, "context slot %d changed kind between visits", static_cast<int>(i));
              return false;
            }
            old_slots[i] = Slot::any();
          }
        }
      }
      // Verify the block now, in this context.
      verify_method(id, c);
      if (run->aborted) return false;
      // Method-id slots that nested blocks turn into block references must
      // stay intact while this frame lives.
      for (int index : c->block_accesses) {
        bool frame;
        Slot* s = state->at(index, &frame);
        if (s != null && (s->kind == K_METHOD_ID || s->kind == K_BLOCK)) s->captured = 1;
      }
      return true;
    }
    case LOAD_GLOBAL_VAR: case LOAD_GLOBAL_VAR_WIDE:
    case LOAD_GLOBAL_VAR_LAZY: case LOAD_GLOBAL_VAR_LAZY_WIDE: {
      bool wide = opcode == LOAD_GLOBAL_VAR_WIDE || opcode == LOAD_GLOBAL_VAR_LAZY_WIDE;
      int index = wide ? OPERAND_U16(1) : OPERAND_U8(1);
      if (index >= program_->global_variables.length()) {
        error(run, bci, "global index %d out of bounds (%d)", index, static_cast<int>(program_->global_variables.length()));
        return false;
      }
      return push(run, state, Slot::any());
    }
    case STORE_GLOBAL_VAR: case STORE_GLOBAL_VAR_WIDE: {
      int index = opcode == STORE_GLOBAL_VAR_WIDE ? OPERAND_U16(1) : OPERAND_U8(1);
      if (index >= program_->global_variables.length()) {
        error(run, bci, "global index %d out of bounds (%d)", index, static_cast<int>(program_->global_variables.length()));
        return false;
      }
      if (state->height() < 1) { error(run, bci, "STORE_GLOBAL_VAR on empty stack"); return false; }
      return true;
    }
    case LOAD_GLOBAL_VAR_DYNAMIC:
      if (!pop(run, state, bci)) return false;
      return push(run, state, Slot::any());
    case STORE_GLOBAL_VAR_DYNAMIC:
      return pop_n(run, state, bci, 2);
    case LOAD_BLOCK: {
      int index = OPERAND_U8(1);
      bool frame;
      Slot* s = state->at(index, &frame);
      if (s == null || s->kind != K_METHOD_ID) {
        error(run, bci, "LOAD_BLOCK of slot S%d which does not hold a block method id (%s)",
              index, s == null ? "no slot" : kind_name(s->kind));
        return false;
      }
      return push(run, state, Slot::make(K_BLOCK, s->aux));
    }
    case LOAD_OUTER_BLOCK: {
      int index = OPERAND_U8(1);
      if (!pop(run, state, bci, &slot)) return false;
      if (!require_block(run, state, bci, slot, "LOAD_OUTER_BLOCK", &context)) return false;
      if (context == null) { error(run, bci, "LOAD_OUTER_BLOCK through opaque block"); return false; }
      bool frame;
      Slot* s = context->state.at(index, &frame);
      if (s == null || s->kind != K_METHOD_ID) {
        error(run, bci, "LOAD_OUTER_BLOCK of outer slot %d which does not hold a block method id", index);
        return false;
      }
      context->block_accesses.push_back(index);
      return push(run, state, Slot::make(K_BLOCK, s->aux));
    }
    case POP:
      return pop_n(run, state, bci, OPERAND_U8(1));
    case POP_1:
      return pop(run, state, bci);
    case ALLOCATE:
    case ALLOCATE_WIDE: {
      int class_id = opcode == ALLOCATE ? OPERAND_U8(1) : OPERAND_U16(1);
      if (class_id >= class_count_) { error(run, bci, "ALLOCATE of invalid class %d", class_id); return false; }
      if (class_tag(class_id) != INSTANCE_TAG) {
        error(run, bci, "ALLOCATE of class %d with non-instance tag %d", class_id, class_tag(class_id));
        return false;
      }
      return push(run, state, Slot::make(K_ALLOC, class_id));
    }
    case IS_CLASS: case IS_CLASS_WIDE: case AS_CLASS: case AS_CLASS_WIDE: {
      bool wide = opcode == IS_CLASS_WIDE || opcode == AS_CLASS_WIDE;
      int encoded = wide ? OPERAND_U16(1) : OPERAND_U8(1);
      int index = encoded >> 1;
      bool nullable = (encoded & 1) != 0;
      int start, end;
      if (!range_for_check_index(index, &start, &end)) {
        error(run, bci, "class check index %d out of bounds", index);
        return false;
      }
      if (state->height() < 1) { error(run, bci, "type check on empty stack"); return false; }
      Slot& top = state->stack.back();
      if (opcode == IS_CLASS || opcode == IS_CLASS_WIDE) {
        top = Slot::any();
      } else if (!nullable && (top.kind == K_ANY || top.kind == K_PARAM || top.kind == K_THIS || top.kind == K_CHECKED)) {
        top = Slot::make(K_CHECKED, index);  // The check succeeded if we continue.
      }
      return true;
    }
    case IS_INTERFACE: case IS_INTERFACE_WIDE: case AS_INTERFACE: case AS_INTERFACE_WIDE: {
      bool wide = opcode == IS_INTERFACE_WIDE || opcode == AS_INTERFACE_WIDE;
      int encoded = wide ? OPERAND_U16(1) : OPERAND_U8(1);
      int index = encoded >> 1;
      if (index >= program_->interface_check_offsets.length()) {
        error(run, bci, "interface check index %d out of bounds", index);
        return false;
      }
      if (state->height() < 1) { error(run, bci, "type check on empty stack"); return false; }
      if (opcode == IS_INTERFACE || opcode == IS_INTERFACE_WIDE) state->stack.back() = Slot::any();
      return true;
    }
    case AS_LOCAL: {
      int encoded = OPERAND_U8(1);
      int local = encoded >> 5;
      int index = encoded & 0x1f;
      int start, end;
      if (!range_for_check_index(index, &start, &end)) {
        error(run, bci, "class check index %d out of bounds", index);
        return false;
      }
      bool frame;
      Slot* s = state->at(local, &frame);
      if (s == null) { error(run, bci, "AS_LOCAL of inaccessible slot S%d", local); return false; }
      if (s->kind == K_ANY || s->kind == K_PARAM || s->kind == K_THIS || s->kind == K_CHECKED) {
        *s = Slot::make(K_CHECKED, index);
      }
      return true;
    }
    case INVOKE_STATIC:
    case INVOKE_STATIC_TAIL: {
      int offset = OPERAND_U16(1);
      if (offset >= dispatch_length_ || program_->dispatch_table[offset] == -1) {
        error(run, bci, "INVOKE_STATIC with invalid dispatch offset %d", offset);
        return false;
      }
      int id = program_->dispatch_table[offset];
      Method target = method_at(id);
      if (!target.is_normal_method() && !target.is_field_accessor()) {
        error(run, bci, "INVOKE_STATIC of method %d which is a block or lambda", id);
        return false;
      }
      mark_static_target(id);
      MethodInfo& ti = info(id);
      int arity = target.arity();
      if (opcode == INVOKE_STATIC_TAIL) {
        int height = OPERAND_U8(3);
        int outer_arity = OPERAND_U8(4);
        if (height != state->height() || outer_arity != method.arity()) {
          error(run, bci, "INVOKE_STATIC_TAIL height/arity %d/%d do not match frame %d/%d",
                height, outer_arity, state->height(), method.arity());
          return false;
        }
      }
      if (!check_call_args(run, state, bci, id, arity, ti.required_mask)) return false;
      int check_index = receiver_check_index(target);
      if (check_index >= 0 && arity >= 1 && final_pass_) {
        stats_->static_instance_calls++;
        Slot receiver = state->stack[state->height() - arity];
        if (check_receiver_range(run, bci, receiver, check_index, "static call to instance method")) {
          stats_->static_instance_calls_proven++;
        }
      }
      if (!pop_n(run, state, bci, arity)) return false;
      if (opcode == INVOKE_STATIC_TAIL) {
        if (!ti.never_returns) run->may_return = true;
        *next = -1;
        return true;
      }
      if (ti.never_returns) { *next = -1; return true; }
      return push(run, state, Slot::any());
    }
    case INVOKE_BLOCK: {
      int index = OPERAND_U8(1);
      if (index < 1 || index > state->height()) {
        error(run, bci, "INVOKE_BLOCK %d with stack height %d", index, state->height());
        return false;
      }
      slot = state->stack[state->height() - index];
      if (!require_block(run, state, bci, slot, "INVOKE_BLOCK", &context)) return false;
      // Passing too few arguments is reported at run time (code_failure);
      // the compiler emits such calls on purpose (tests/negative/block-call2).
      if (!pop_n(run, state, bci, index)) return false;
      return push(run, state, Slot::any());
    }
    case INVOKE_LAMBDA_TAIL: {
      int parameters = OPERAND_U8(1);
      if (state->height() != 0 || method.arity() != parameters + 1) {
        error(run, bci, "INVOKE_LAMBDA_TAIL %d needs empty stack and arity %d (height %d, arity %d)",
              parameters, parameters + 1, state->height(), method.arity());
        return false;
      }
      if (final_pass_) {
        stats_->heap_method_id_sites++;
        for (int c : info(run->method_id).receiver_classes) lambda_classes_.insert(c);
      }
      // The receiver must be a Lambda_ instance with at least two fields.
      // The dispatch witness covers it when the method is a virtual target.
      Slot receiver = state->params[0];
      if (!check_field_receiver(run, bci, receiver, 1, false)) return false;
      // On failure the interpreter calls code_failure and returns here.
      run->may_return = true;
      return push(run, state, Slot::any());
    }
    case INVOKE_INITIALIZER_TAIL: {
      int height = OPERAND_U8(1);
      int outer_arity = OPERAND_U8(2);
      if (height != state->height() || outer_arity != method.arity()) {
        error(run, bci, "INVOKE_INITIALIZER_TAIL height/arity %d/%d do not match frame %d/%d",
              height, outer_arity, state->height(), method.arity());
        return false;
      }
      if (!pop(run, state, bci)) return false;
      if (final_pass_) stats_->heap_method_id_sites++;
      run->may_return = true;
      *next = -1;
      return true;
    }
    case INVOKE_VIRTUAL:
    case INVOKE_VIRTUAL_WIDE: {
      int arity = (opcode == INVOKE_VIRTUAL ? OPERAND_U8(1) : OPERAND_U16(1)) + 1;
      int selector = OPERAND_U16(opcode == INVOKE_VIRTUAL ? 2 : 3);
      uint64 mask;
      if (!selector_arity_ok(run, bci, selector, arity, &mask)) return false;
      if (!check_call_args(run, state, bci, -1, arity, mask)) return false;
      if (!pop_n(run, state, bci, arity)) return false;
      return push(run, state, Slot::any());
    }
    case INVOKE_VIRTUAL_GET:
    case INVOKE_VIRTUAL_SET:
    case INVOKE_SIZE: {
      int arity = opcode == INVOKE_VIRTUAL_SET ? 2 : 1;
      int selector = OPERAND_U16(1);
      uint64 mask;
      if (!selector_arity_ok(run, bci, selector, arity, &mask)) return false;
      if (!check_call_args(run, state, bci, -1, arity, mask)) return false;
      if (!pop_n(run, state, bci, arity)) return false;
      return push(run, state, Slot::any());
    }
    case INVOKE_EQ: case INVOKE_LT: case INVOKE_GT: case INVOKE_LTE: case INVOKE_GTE:
    case INVOKE_BIT_OR: case INVOKE_BIT_XOR: case INVOKE_BIT_AND:
    case INVOKE_BIT_SHL: case INVOKE_BIT_SHR: case INVOKE_BIT_USHR:
    case INVOKE_ADD: case INVOKE_SUB: case INVOKE_MUL: case INVOKE_DIV: case INVOKE_MOD:
    case INVOKE_AT: case INVOKE_AT_PUT: {
      int arity = opcode == INVOKE_AT_PUT ? 3 : 2;
      int selector = program_->invoke_bytecode_offset(static_cast<Opcode>(opcode));
      if (selector < 0) {
        error(run, bci, "%s used but its selector is not in the program", kOpcodeName[opcode]);
        return false;
      }
      uint64 mask;
      if (!selector_arity_ok(run, bci, selector, arity, &mask)) return false;
      if (!check_call_args(run, state, bci, -1, arity, mask)) return false;
      if (!pop_n(run, state, bci, arity)) return false;
      return push(run, state, Slot::any());
    }
    case IDENTICAL:
      if (!pop_n(run, state, bci, 2)) return false;
      return push(run, state, Slot::any());
    case BRANCH: case BRANCH_IF_TRUE: case BRANCH_IF_FALSE: case BRANCH_IF_NOT_NULL: {
      int target = bci + OPERAND_U16(1);
      if (target == bci) {
        // Forward branches carry no preemption check; a zero offset would be
        // a loop the scheduler cannot interrupt.
        error(run, bci, "forward branch with zero offset");
        return false;
      }
      if (opcode != BRANCH && !pop(run, state, bci)) return false;
      if (!add_entry(run, target, *state, bci)) return false;
      if (opcode == BRANCH) *next = -1;
      return true;
    }
    case BRANCH_BACK: case BRANCH_BACK_IF_TRUE: case BRANCH_BACK_IF_FALSE: case BRANCH_BACK_IF_NOT_NULL: {
      int target = bci - OPERAND_U16(1);
      int entry = OPERAND_U16(3);
      if (entry != bci - run->entry_bci) {
        error(run, bci, "BRANCH_BACK entry operand %d does not point to the method entry (%d)",
              entry, bci - run->entry_bci);
        return false;
      }
      if (opcode != BRANCH_BACK && !pop(run, state, bci)) return false;
      if (!add_entry(run, target, *state, bci)) return false;
      if (opcode == BRANCH_BACK) *next = -1;
      return true;
    }
    case PRIMITIVE: {
      int module = OPERAND_U8(1);
      int index = OPERAND_U16(2);
      if (module >= kPrimitiveModuleCount || index >= kPrimitiveModuleSizes[module]) {
        error(run, bci, "primitive %d:%d does not exist", module, index);
        return false;
      }
      int arity = kPrimitiveArities[module][index];
      if (arity != method.arity() || state->height() != 0) {
        error(run, bci, "primitive %d:%d (arity %d) called from method with arity %d and height %d",
              module, index, arity, method.arity(), state->height());
        return false;
      }
      if (final_pass_) {
        stats_->primitive_sites++;
        primitives_used_.insert(module << 16 | index);
      }
      // A primitive that succeeds returns to the caller; a failing one falls through.
      run->may_return = true;
      return push(run, state, Slot::any());
    }
    case THROW:
      if (state->height() < 1) { error(run, bci, "THROW on empty stack"); return false; }
      *next = -1;
      return true;
    case RETURN:
    case RETURN_NULL: {
      int height = OPERAND_U8(1);
      int arity = OPERAND_U8(2);
      int minimum = opcode == RETURN ? 1 : 0;
      if (height != state->height() || arity != method.arity() || state->height() < minimum) {
        error(run, bci, "%s %d/%d does not match frame height %d / arity %d",
              kOpcodeName[opcode], height, arity, state->height(), method.arity());
        return false;
      }
      run->may_return = true;
      *next = -1;
      return true;
    }
    case NON_LOCAL_RETURN:
    case NON_LOCAL_RETURN_WIDE: {
      int arity, height;
      if (opcode == NON_LOCAL_RETURN) {
        int encoded = OPERAND_U8(1);
        arity = encoded & 0x0f;
        height = encoded >> 4;
      } else {
        arity = OPERAND_U16(1);
        height = OPERAND_U16(3);
      }
      if (!pop(run, state, bci, &slot)) return false;
      if (!pop(run, state, bci)) return false;  // The result.
      if (!require_block(run, state, bci, slot, "NON_LOCAL_RETURN", &context)) return false;
      if (context == null) { error(run, bci, "non-local return through opaque block"); return false; }
      if (height != context->state.height() - 1 || arity != context->owner_arity) {
        error(run, bci, "NON_LOCAL_RETURN height/arity %d/%d do not match target frame %d/%d",
              height, arity, context->state.height() - 1, context->owner_arity);
        return false;
      }
      context->owner->may_return = true;
      *next = -1;
      return true;
    }
    case NON_LOCAL_BRANCH: {
      int height_diff = OPERAND_U8(1);
      int target = static_cast<int>(OPERAND_U32(2));
      if (!pop(run, state, bci, &slot)) return false;
      if (!require_block(run, state, bci, slot, "NON_LOCAL_BRANCH", &context)) return false;
      if (context == null) { error(run, bci, "non-local branch through opaque block"); return false; }
      if (height_diff > context->state.height()) {
        error(run, bci, "NON_LOCAL_BRANCH drops %d slots of a frame with height %d",
              height_diff, context->state.height());
        return false;
      }
      State target_state = context->state;
      target_state.stack.resize(context->state.height() - height_diff);
      if (!add_entry(context->owner, target, target_state, bci)) return false;
      *next = -1;
      return true;
    }
    case LINK: {
      push(run, state, Slot::make(K_LINK_RESULT));
      push(run, state, Slot::make(K_LINK_TARGET));
      push(run, state, Slot::make(K_LINK_REASON));
      push(run, state, Slot::make(K_LINK_CHAIN));
      return check_try_shape(run, state, bci);
    }
    case UNLINK: {
      if (!pop(run, state, bci, &slot)) return false;
      if (slot.kind != K_LINK_CHAIN) { error(run, bci, "UNLINK pops %s", kind_name(slot.kind)); return false; }
      return true;
    }
    case UNWIND: {
      if (state->height() < 3) { error(run, bci, "UNWIND with height %d", state->height()); return false; }
      Slot reason = state->stack[state->height() - 1];
      Slot target = state->stack[state->height() - 2];
      Slot result = state->stack[state->height() - 3];
      if (reason.kind != K_LINK_REASON || target.kind != K_LINK_TARGET || result.kind != K_LINK_RESULT) {
        error(run, bci, "UNWIND without link slots on top (%s, %s, %s)",
              kind_name(reason.kind), kind_name(target.kind), kind_name(result.kind));
        return false;
      }
      return pop_n(run, state, bci, 3);
    }
    case HALT: {
      int code = OPERAND_U8(1);
      if (code > 3) { error(run, bci, "HALT %d", code); return false; }
      if (untrusted_ && code >= 2) {
        // Deep sleep (2) and reset (3) terminate the whole VM.
        error(run, bci, "HALT %d (%s) is not allowed in untrusted programs",
              code, code == 2 ? "deep sleep" : "reset");
        return false;
      }
      if (code == 0) return push(run, state, Slot::any());  // Resumes after yield with a value.
      if (code == 1 || code == 2) { if (!pop(run, state, bci)) return false; }
      *next = -1;
      return true;
    }
    case INTRINSIC_SMI_REPEAT:
    case INTRINSIC_ARRAY_DO:
    case INTRINSIC_HASH_FIND:
    case INTRINSIC_HASH_DO: {
      // Each intrinsic assumes a specific frame: the receiver is parameter 0
      // and the block(s) are the last parameters; see interpreter_run.cc.
      int arity, height, blocks, receiver_fields;
      int receiver_tag = -1;
      switch (opcode) {
        case INTRINSIC_SMI_REPEAT: arity = 2; height = 2; blocks = 1; receiver_fields = -1; break;
        case INTRINSIC_ARRAY_DO:   arity = 3; height = 2; blocks = 1; receiver_fields = -1; receiver_tag = ARRAY_TAG; break;
        case INTRINSIC_HASH_FIND:  arity = 7; height = 8; blocks = 3; receiver_fields = Instance::MAP_BACKING_INDEX + 1; break;
        default:                   arity = 4; height = 2; blocks = 1; receiver_fields = Instance::MAP_BACKING_INDEX + 1; break;
      }
      if (method.arity() != arity || state->height() != height) {
        error(run, bci, "%s needs arity %d and height %d (found %d and %d)",
              kOpcodeName[opcode], arity, height, method.arity(), state->height());
        return false;
      }
      for (int i = 0; i < blocks; i++) {
        if (!require_block(run, state, bci, state->params[arity - 1 - i], kOpcodeName[opcode], &context)) return false;
      }
      Slot receiver = state->params[0];
      if (receiver_fields >= 0) {
        if (!check_field_receiver(run, bci, receiver, receiver_fields - 1, false)) return false;
      } else if (receiver_tag >= 0 && final_pass_) {
        bool ok = receiver.kind == K_THIS;
        if (ok) for (int c : info(receiver.aux).receiver_classes) if (class_tag(c) != receiver_tag) ok = false;
        if (!ok) warning(run, bci, "%s receiver not proven to have class tag %d", kOpcodeName[opcode], receiver_tag);
      }
      run->may_return = true;
      int dropped = opcode == INTRINSIC_HASH_FIND ? 7 : 1;
      return pop_n(run, state, bci, dropped);
    }
    default:
      error(run, bci, "unhandled opcode %d", opcode);
      return false;
  }
}

#undef OPERAND_U8
#undef OPERAND_U16
#undef OPERAND_U32

bool VerifierImpl::process_worklist(MethodRun* run) {
  while (!run->worklist.empty() && !run->aborted) {
    int bci = run->worklist.back();
    run->worklist.pop_back();
    State state = run->entries.at(bci);
    while (true) {
      int next;
      if (!step(run, &state, bci, &next)) return false;
      if (next < 0) break;
      // Fall through: continue immediately if this is the first visit.
      auto probe = run->entries.find(next);
      if (probe == run->entries.end()) {
        run->entries.emplace(next, state);
        bci = next;
        continue;
      }
      if (!add_entry(run, next, state, bci)) return false;
      break;
    }
  }
  return !run->aborted;
}

void VerifierImpl::verify_method(int method_id, Context* context) {
  MethodInfo& mi = info(method_id);
  if (context == null) {
    if (mi.seen_in_pass) return;
    mi.seen_in_pass = true;
  }
  if (++run_depth_ > 64) {
    error(null, method_id, "block nesting too deep");
    run_depth_--;
    return;
  }
  Method method = method_at(method_id);
  MethodRun run;
  run.method_id = method_id;
  run.method = method;
  run.entry_bci = method_id + METHOD_HEADER_SIZE;
  run.context = context;
  run.depth = run_depth_;
  if (final_pass_) {
    stats_->methods++;
    if (method.is_block_method()) stats_->blocks++;
    if (method.is_lambda_method()) stats_->lambdas++;
  }
  if (final_pass_ && run_depth_ > stats_->max_block_depth) stats_->max_block_depth = run_depth_;
  if (context == null && method.is_block_method()) {
    error(&run, run.entry_bci, "block method reached without a context");
  } else {
    State initial = initial_state(method_id, context);
    run.entries.emplace(run.entry_bci, initial);
    run.worklist.push_back(run.entry_bci);
    if (process_worklist(&run) && !run.had_error) {
      if (run.max_height > method.max_height()) {
        error(&run, run.entry_bci, "stack height %d exceeds declared max height %d",
              run.max_height, method.max_height());
      }
      if (method.max_height() > global_max_height_) global_max_height_ = method.max_height();
      if (!run.may_return && !mi.never_returns) {
        mi.never_returns = true;
        changed_ = true;
      }
      // Field accessors are read directly by INVOKE_VIRTUAL_GET/SET.
      if (method.is_field_accessor()) {
        uint8* e = method.entry();
        int field = -1;
        bool shape_ok = false;
        if (method.arity() == 1) {
          if (e[0] == LOAD_FIELD_LOCAL && (e[1] & 0x0f) == FRAME_SIZE && e[2] == RETURN) {
            shape_ok = true; field = e[1] >> 4;
          } else if (e[0] == LOAD_LOCAL_2 && e[1] == LOAD_FIELD && e[3] == RETURN) {
            shape_ok = true; field = e[2];
          }
        } else if (method.arity() == 2) {
          if (e[0] == LOAD_LOCAL_3 && e[1] == LOAD_LOCAL_3 && e[2] == STORE_FIELD && e[4] == RETURN) {
            shape_ok = true; field = e[3];
          }
        }
        if (!shape_ok) {
          error(&run, run.entry_bci, "field accessor does not have the expected shape");
        } else {
          for (int c : mi.receiver_classes) {
            if (instance_fields(c) <= field) {
              error(&run, run.entry_bci, "field accessor for field %d reachable from class %d with %d fields",
                    field, c, instance_fields(c));
            }
          }
        }
      }
    }
  }
  if (final_pass_) {
    if (static_cast<int>(run.entries.size()) > stats_->max_states) stats_->max_states = run.entries.size();
    if (run.max_height + method.arity() > stats_->max_frame_slots) stats_->max_frame_slots = run.max_height + method.arity();
  }
  run_depth_--;
}

// ----------------------------------------------------------------------------

bool VerifierImpl::run() {
  int64 start = OS::get_monotonic_time();
  if (!check_tables()) {
    for (const std::string& e : errors_) fprintf(stderr, "verifier: %s\n", e.c_str());
    stats_->errors = static_cast<int>(errors_.size());
    stats_->time_us = OS::get_monotonic_time() - start;
    return false;
  }
  collect_dispatch_info();

  // Fixpoint over the block-parameter requirements, static-target marks and
  // never-returns facts. All of them only grow, so this terminates.
  std::vector<std::string> last_errors;
  while (true) {
    pass_++;
    changed_ = false;
    errors_.clear();
    warnings_.clear();
    unique_warnings_.clear();
    for (Context* c : contexts_) delete c;
    contexts_.clear();
    contexts_.push_back(null);  // Context id 0 means "opaque".
    for (auto& it : infos_) {
      it.second.seen_in_pass = false;
      it.second.load_site = -1;
    }
    for (size_t i = 0; i < roots_.size(); i++) verify_method(roots_[i], null);
    if (final_pass_) break;
    if (!changed_ || pass_ >= MAX_PASSES - 1) {
      // One more pass with statistics and diagnostics enabled.
      final_pass_ = true;
    }
  }
  if (changed_) error(null, -1, "fixpoint did not converge after %d passes", pass_);
  check_heap_method_ids();
  check_method_entries();

  // Method headers store the max height rounded up to a multiple of 4,
  // while the global max is computed from the unrounded values.
  if (global_max_height_ > Utils::round_up(program_->global_max_stack_height(), 4)) {
    error(null, -1, "method max height %d exceeds global max stack height %d",
          global_max_height_, program_->global_max_stack_height());
  }
  // Failure entry points are invoked by the interpreter on paths that are
  // not stack-consistent if they return; they must throw.
#define CHECK_NEVER_RETURNS(name, lib_name, ep_arity)                                   \
  if (Program::name##_INDEX != Program::entry_main_INDEX &&                           \
      Program::name##_INDEX != Program::entry_spawn_INDEX &&                          \
      Program::name##_INDEX != Program::entry_task_INDEX &&                           \
      Program::name##_INDEX != Program::run_global_initializer_INDEX) {               \
    int di = program_->entry_point_indexes_[Program::name##_INDEX];                     \
    int id = di == -1 ? -1 : program_->dispatch_table[di];                              \
    if (id != -1 && !info(id).never_returns) error(null, id, "failure entry point %s may return normally", lib_name); \
  }
  ENTRY_POINTS(CHECK_NEVER_RETURNS)
#undef CHECK_NEVER_RETURNS

  stats_->passes = pass_;
  stats_->errors = static_cast<int>(errors_.size());
  stats_->warnings = static_cast<int>(warnings_.size());
  stats_->distinct_primitives = static_cast<int>(primitives_used_.size());
  stats_->time_us = OS::get_monotonic_time() - start;

  int reported = 0;
  for (const std::string& e : errors_) {
    if (reported++ >= MAX_REPORTED_ERRORS) { fprintf(stderr, "verifier: ... %d more errors\n", stats_->errors - reported + 1); break; }
    fprintf(stderr, "verifier: error %s\n", e.c_str());
  }
  if (verbosity_ >= 2) {
    for (const std::string& w : warnings_) fprintf(stderr, "verifier: warning %s\n", w.c_str());
  }
  if (verbosity_ >= 1) {
    fprintf(stderr, "verifier: %s in %d passes, %" PRId64 " us\n",
            errors_.empty() ? "OK" : "FAILED", pass_, stats_->time_us);
    fprintf(stderr, "verifier:   methods %d (blocks %d, lambdas %d), instructions %d, bytes %d of %d\n",
            stats_->methods, stats_->blocks, stats_->lambdas, stats_->instructions, stats_->bytes, bytecodes_length_);
    fprintf(stderr, "verifier:   field sites %d: this %d, alloc %d, range %d, unproven %d (checked at run time)\n",
            stats_->field_sites, stats_->field_sites_this, stats_->field_sites_alloc,
            stats_->field_sites_range, stats_->field_sites_unproven);
    fprintf(stderr, "verifier:   static calls to instance methods %d (receiver proven %d), heap method-id sites %d, method entries %d\n",
            stats_->static_instance_calls, stats_->static_instance_calls_proven, stats_->heap_method_id_sites,
            stats_->method_entries);
    fprintf(stderr, "verifier:   primitive sites %d (%d distinct), classes %d, dispatch entries %d, errors %d, warnings %d\n",
            stats_->primitive_sites, stats_->distinct_primitives, class_count_, dispatch_length_,
            stats_->errors, stats_->warnings);
    fprintf(stderr, "verifier:   synthetic terminators (LOAD_NULL; THROW) %d\n", stats_->synthetic_terminators);
    fprintf(stderr, "verifier:   max states per method %d, max frame slots %d, max block depth %d\n",
            stats_->max_states, stats_->max_frame_slots, stats_->max_block_depth);
    fprintf(stderr, "verifier:   program heap: %d objects, %d bytes, %d references checked, %d lambda classes\n",
            stats_->heap_objects, stats_->heap_bytes, stats_->heap_references, static_cast<int>(lambda_classes_.size()));
  }
  if (print_primitives_) print_primitives();
  for (Context* c : contexts_) delete c;
  contexts_.clear();
  return errors_.empty();
}

// The interpreter checks method ids that it reads from the stack or the heap
// against a table of method entries that it computes when the program is
// loaded. Every method the verifier reached must be in that table, otherwise
// a verified program would fail at run time.
bool VerifierImpl::check_method_entries() {
  MethodEntryTable* table = MethodEntryTable::compute(program_);
  if (table == null) {
    error(null, -1, "could not compute the method entry table");
    return false;
  }
  bool ok = true;
  for (int id : method_starts_) {
    if (!table->is_entry(id)) {
      error(null, id, "method %d is not in the method entry table", id);
      ok = false;
    }
  }
  stats_->method_entries = static_cast<int>(table->count());
  delete table;
  return ok;
}

void VerifierImpl::print_primitives() {
  std::vector<int> sorted(primitives_used_.begin(), primitives_used_.end());
  std::sort(sorted.begin(), sorted.end());
  printf("primitives %d:", static_cast<int>(sorted.size()));
  for (int encoded : sorted) {
    int module = encoded >> 16;
    int index = encoded & 0xffff;
    printf(" %s.%s", kPrimitiveModuleNames[module], kPrimitiveNames[module][index]);
  }
  printf("\n");
}

Program* VerifierImpl::override_program_ = null;
uint8* VerifierImpl::override_bytecodes_ = null;
int VerifierImpl::override_length_ = 0;
uint8* VerifierImpl::coverage_ = null;

void Verifier::set_coverage_for_testing(uint8* coverage) {
  VerifierImpl::coverage_ = coverage;
}

// Verification is enabled with -Xverify or with TOIT_VERIFY=1.
// TOIT_VERIFY_VERBOSE selects the verbosity.
bool Verifier::is_enabled() {
  const char* env = getenv("TOIT_VERIFY");
  return Flags::verify || (env != null && env[0] != '\0' && env[0] != '0');
}

static bool verify_and_report(Program* program, bool untrusted) {
  const char* verbose = getenv("TOIT_VERIFY_VERBOSE");
  VerifierOptions options;
  options.verbosity = verbose != null ? atoi(verbose) : 0;
  options.untrusted = untrusted;
  VerifierStats stats;
  if (!Verifier::verify(program, &stats, options)) {
    fprintf(stderr, "verifier: %sprogram rejected (%d errors)\n",
            untrusted ? "untrusted " : "", stats.errors);
    return false;
  }
  return true;
}

bool Verifier::verify_if_enabled(Program* program, bool untrusted) {
  if (!is_enabled()) return true;
  return verify_and_report(program, untrusted);
}

bool Verifier::verify_for_policy(Program* program, const PrimitivePolicy* policy) {
  if (policy->is_untrusted()) return verify_and_report(program, true);
  return verify_if_enabled(program, false);
}

void Verifier::set_bytecodes_for_testing(Program* program, uint8* bytes, int length) {
  VerifierImpl::set_bytecodes(program, bytes, length);
}

bool Verifier::verify(Program* program, VerifierStats* stats, const VerifierOptions& options) {
  VerifierStats local;
  if (stats == null) stats = &local;
  AllowThrowingNew allow;
  VerifierImpl impl(program, stats, options);
  return impl.run();
}

} // namespace toit

#else  // !defined(TOIT_FREERTOS)

namespace toit {

// The verifier runs on the host (at install time); devices do not
// verify programs yet.
bool Verifier::verify(Program* program, VerifierStats* stats, const VerifierOptions& options) {
  return false;
}

bool Verifier::is_enabled() {
  return false;
}

bool Verifier::verify_if_enabled(Program* program, bool untrusted) {
  return true;
}

// Without the verifier, untrusted programs can not be admitted.
bool Verifier::verify_for_policy(Program* program, const PrimitivePolicy* policy) {
  return !policy->is_untrusted();
}

void Verifier::set_bytecodes_for_testing(Program* program, uint8* bytes, int length) {}
void Verifier::set_coverage_for_testing(uint8* coverage) {}

} // namespace toit

#endif  // !defined(TOIT_FREERTOS)
