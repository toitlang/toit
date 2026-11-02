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

#include "native_generator.h"

#include "native_code_writer.h"

#include "propagation/type_database.h"

#include "../bytecodes.h"
#include "../flags.h"
#include "../interpreter.h"
#include "../native.h"
#include "native_abi_source.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../program.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <utility>
#include <iterator>
#include <vector>
#include <set>
#include <sstream>
#include <tuple>

namespace toit {
namespace compiler {

#define BYTECODE_LENGTH(name, length, format, print) length,
static const int opcode_length[] { BYTECODES(BYTECODE_LENGTH) -1 };
#undef BYTECODE_LENGTH

// Generates C++ for a program. Each basic block of bytecodes becomes a function
// that ends in a tail call, and the top of the stack is in a register.
//
// This happens in two passes. The analysis finds out what can run, which basic
// blocks that leaves, what is hot and what to inline, and nothing changes after
// that. Emitting the code just reads the results, so the two passes can't
// disagree on the shape of the code.
//
// While emitting a block, values that are cheap to get to are tracked instead of
// being written to the stack, and known floats stay unboxed. That lets
// the operations work directly on them. See keep_on_top for how they get written.
class NativeGenerator : private NativeCodeWriter {
 public:
  NativeGenerator(Program* program, TypeDatabase* types, std::vector<int> methods);

  std::string generate();

 private:
  // The result of analyzing the code of a method, which is all that the
  // emission of the code goes by.
  struct BasicBlock {
    uint8* end;
    bool falls_through;       // Continues at the end without a jump in the code of the last bytecode.
    bool has_label;           // Something other than the code of the method can get here.
    int entries;              // The number of places in the method that get here.
    uint8* last_entry;        // The bytecode that gets here. Fall-throughs are from the last in a block.
    bool is_nested;           // Emitted where it's entered, so it isn't a function.
    bool is_hot;              // Part of a loop.
    uint8* last;              // The last bytecode.
    std::vector<uint8*> successors;
  };

  // A call that is replaced by the code of what it calls.
  struct InlinedCall {
    int field;        // The field of an accessor or -1.
    bool can_be_null;
    int leaf;         // The method of a leaf or -1.
  };

  struct MethodInfo {
    Method method;
    uint8* end;
    std::set<uint8*> reachable;
    std::map<uint8*, BasicBlock> blocks;
    // Comparisons of integers that are done as a part of the branch that follows them.
    std::set<uint8*> merged_comparisons;
    std::map<uint8*, InlinedCall> inlined_calls;
    // Float operations that can overwrite an operand instead of allocating.
    // The value is the index of the operand on the stack.
    std::map<uint8*, int> reused_floats;
    bool has_inlined_leaf;
    // Code in loops is hot. The whole method is hot if it is small or recursive.
    bool is_hot;
    bool has_loops;
  };

  Program* const program_;
  TypeDatabase* const types_;
  std::vector<MethodInfo> methods_;
  std::set<int> method_ids_;
  std::set<int> dead_blocks_;  // Blocks that are only called with too few arguments.
  // The code following a call can be gone, but we still need something to
  // use as the return address, because it tells us where the call is.
  std::set<uint8*> dead_continuations_;
  std::set<uint8*> return_points_;
  std::set<int> branch_targets_;  // Absolute bcis of non-local branch targets.
  uint8* current_end_ = null;
  int nesting_ = 0;

  int bci(uint8* bcp) const { return program_->absolute_bci_from_bcp(bcp); }
  int method_id(Method method) const { return bci(method.header_bcp()); }

  // The labels of the generated functions. The method functions check the stack
  // and fall into the code of the method.
  std::string method_label(int id) const {
    if (method_ids_.count(id) == 0) return "NativeRuntime::illegal";
    return "m" + std::to_string(id);
  }
  std::string method_label(Method method) const { return method_label(method_id(method)); }
  std::string virtual_label(int id) const { return "v" + std::to_string(id); }

  std::vector<uint8> pruned_bytecodes_;
  std::map<int, int> pruned_ids_;
  std::map<int, int> pruned_branch_targets_;
  std::string block_entry_label(int id) const {
    return "e" + std::to_string(id);
  }
  std::string label(uint8* bcp) const {
    // The optimizer can remove the code after calls that don't return.
    if (dead_continuations_.count(bcp) != 0) return "d" + std::to_string(bci(bcp));
    if (bcp == current_end_) return "NativeRuntime::illegal";
    return "b" + std::to_string(bci(bcp));
  }

  // What the propagated types tell us about the two operands of a binary operation.
  struct Operands {
    bool left_is_smi = false;
    bool right_is_smi = false;
    bool can_be_smis = true;
    // Even if we don't know that the integers are smis, knowing that
    // they are integers means that there is no Toit code to run.
    bool are_ints = false;
    // Whether the types are precise enough for us to believe that the
    // inlined path will be taken. If the operand could be pretty much
    // anything, it isn't worth paying for code that may never run.
    bool is_likely = false;
    // Floats need no checks if we know that it's what they are, and it's
    // only worth checking for them if it can be the case for both of them.
    bool are_floats = false;
    bool can_be_floats = false;
    bool are_smis() const { return left_is_smi && right_is_smi; }
  };
  Operands operands(uint8* bcp) const;
  // The condition for the operands being smis; empty if they always are.
  std::string smi_check(const Operands& operands, const std::string& left = "STACK_AT(1)", const std::string& right = "STACK_AT(0)") const;
  bool is_smi_type(TypeSet type) const;
  bool is_int_type(TypeSet type) const;

  // Identifies a selector and its arity for the check in the virtual entries.
  static intptr_t virtual_key(int selector_offset, int stack_offset) {
    return static_cast<intptr_t>(selector_offset) << 8 | stack_offset;
  }
  bool has_virtual_entry(int id) const { return virtual_entries_.count(id) != 0; }
  std::set<int> virtual_entries_;

  bool ends_block(uint8* bcp) const;
  bool stays_in_block(uint8* bcp) const;
  // The code that follows calls that don't return isn't needed.
  bool is_dead_continuation(uint8* bcp, uint8* next) const;

  void compute_pruned_bytecodes(const std::vector<int>& methods);
  void update_program();
  int pruned_id(int id) const { return pruned_ids_.at(id); }
  int pruned_entry(int id) const { return pruned_id(id) + Method::entry_offset(); }
  int pruned_branch_target(int target);

  int accessor_field(uint8* bcp, bool* can_be_null) const;
  int getter_field(Method target) const;
  int setter_field(Method target) const;
  bool emit_inlined_accessor(uint8* bcp, uint8* next);

  void find_branch_targets();
  void find_reachable(MethodInfo* info);
  void find_blocks(MethodInfo* info);
  void find_nested_blocks(MethodInfo* info);
  void find_inlined_calls(MethodInfo* info);
  void find_float_temporaries(MethodInfo* info);
  void find_successors(MethodInfo* info);
  bool branches_after_comparison(uint8* next) const;
  void find_hot_code(MethodInfo* info);
  void find_hot_blocks();
  bool is_hot_code(const MethodInfo& info, uint8* bcp) const;
  const char* attributes(const MethodInfo& info, uint8* bcp) const;
  void emit_declarations();
  void emit_primitive_declarations();
  void emit_tables();
  void emit_method(const MethodInfo& info);
  void emit_block_entry(Method method, bool is_dead);
  void emit_block(const MethodInfo& info, uint8* begin);
  void emit_opcode(const MethodInfo& info, uint8* bcp);

  void push(const std::string& value) { line("PUSH(" + value + ");"); }
  void drop(int count) { line(cat("DROP(", count, ");")); }
  void drop_push(int count, const std::string& value) { line(cat("DROP_PUSH(", count, ", ", value, ");")); }
  void stack_at_put(int index, const std::string& value) { line(cat("STACK_AT_PUT(", index, ", ", value, ");")); }
  void spill() { line("SPILL();"); }
  void reload() { line("RELOAD();"); }
  void tail_call(const std::string& target) { line("NATIVE_TAIL " + target + "(NATIVE_ARGS);"); }
  template<typename X, typename Y>
  void tail_call(const std::string& target, const X& x, const Y& y, const std::string& t) {
    line(cat("NATIVE_TAIL ", target, "(sp, c, ", x, ", ", y, ", ", t, ");"));
  }
  template<typename Y>
  void emit_runtime(const char* helper, const std::string& x, const Y& y) {
    spill();
    tail_call(cat("NativeRuntime::", helper), x, y, "t");  // Unused, but setting it takes code.
  }
  void emit_result_if(const std::string& condition, int count, uint8* next);

  // Within a block, loading locals and constants doesn't need any code until
  // something needs the values on the stack. The tracked values go on top of
  // the real stack, which doesn't change while there are any, except that the
  // elements that are dropped first are still there until they are written.
  struct TrackedValue {
    int slot;          // The element of the real stack or -1.
    std::string text;  // The value if it isn't on the stack.
    bool is_double;    // The value is a double that hasn't been boxed.
    std::string at(int adjustment) const { return slot >= 0 ? stack_at(slot + adjustment) : text; }
  };
  std::vector<TrackedValue> tracked_;
  int pending_drops_ = 0;
  int double_count_ = 0;

  void track(const std::string& text);
  void track_local(int index);
  void pop_tracked(int count);
  int keep_on_top(int count, bool allow_doubles = false);
  void flush_stack();
  std::string operand(int index, int kept) const;
  std::string double_operand(int index, int kept) const;
  void emit_box(const std::string& value);
  void emit_int_operation(uint8* bcp, Opcode opcode, const char* helper);
  void emit_float_operation(uint8* bcp, const char* float_op);
  bool uses_tracked_stack(const MethodInfo& info, uint8* bcp) const;
  std::string pop_for_branch();
  std::string truth_of(uint8* bcp, const std::string& value) const;
  bool needs_write_barrier(uint8* bcp, int index) const;
  void emit_loop_intrinsic(uint8* bcp, bool is_array);
  void emit_store_field(const char* instance, int field, bool needs_barrier);
  void emit_load_field(int field);

  void declare(const char* attributes, const std::string& name);
  void emit_goto(uint8* target);
  void emit_frame(const std::string& return_address, bool is_hot);
  void emit_call(int id, uint8* next);
  void emit_runtime_next(const char* helper, uint8* next, word y);
  typedef std::tuple<int, int, bool> VirtualThunk;
  std::set<VirtualThunk> virtual_thunks_;
  std::string thunk_label(const VirtualThunk& thunk) const {
    return "v" + std::to_string(std::get<0>(thunk)) + "_" + std::to_string(std::get<1>(thunk)) +
        (std::get<2>(thunk) ? "_s" : "");
  }
  bool is_hot_site(uint8* bcp) const { return is_hot_code(*current_info_, bcp); }
  const MethodInfo* current_info_ = null;
  std::string class_id_expression(const std::string& receiver, bool can_be_smi) const;
  bool emit_direct_calls(uint8* bcp, uint8* next, int stack_offset, int selector_offset);
  bool find_targets(uint8* bcp, int stack_offset, int selector_offset, std::set<int>* targets, bool* can_be_null) const;
  bool is_leaf(Method method) const;
  int leaf_target(uint8* bcp) const;
  bool emit_inlined_leaf(const MethodInfo& info, uint8* bcp);
  void emit_virtual(uint8* bcp, uint8* next, int stack_offset, int selector_offset);
  void emit_arithmetic(uint8* bcp, uint8* next, Opcode opcode, const char* helper, const char* float_op = null);
  void emit_relational(uint8* bcp, uint8* next, Opcode opcode, const char* op);
  void emit_bit_operation(uint8* bcp, uint8* next, Opcode opcode, const char* op, const char* helper);
  struct Collection {
    const char* name;
    std::string guard;
  };
  std::vector<Collection> collections_at(uint8* bcp, int stack_offset) const;
  void emit_at(uint8* bcp, uint8* next);
  void emit_at_put(uint8* bcp, uint8* next);
  void emit_size(uint8* bcp, uint8* next, int selector);
  void emit_fast_result(uint8* next, const std::string& result);
  void emit_branch(uint8* target, const std::string& condition, bool is_back, uint8* entry);
  void emit_typecheck(uint8* bcp, Opcode opcode, bool is_as, int encoded, int length);
  void emit_tail_frame_move(int height, int outer_arity, int call_arity);
};

NativeGenerator::NativeGenerator(Program* program, TypeDatabase* types, std::vector<int> methods)
    : program_(program)
    , types_(types) {
  std::sort(methods.begin(), methods.end());
  methods.erase(std::unique(methods.begin(), methods.end()), methods.end());
  for (unsigned i = 0; i < methods.size(); i++) {
    if (types->is_dead_method(methods[i])) continue;
    uint8* end = (i + 1 == methods.size())
        ? program->bytecodes.data() + program->bytecodes.length()
        : program->bcp_from_absolute_bci(methods[i + 1]);
    methods_.push_back({ Method(program->bytecodes, methods[i]), end, {}, {}, {}, {}, {}, false, false, false });
    method_ids_.insert(methods[i]);
  }
  find_branch_targets();
  for (auto& info : methods_) {
    find_reachable(&info);
    find_blocks(&info);
    find_hot_code(&info);
  }
  find_hot_blocks();
  for (auto& info : methods_) {
    find_inlined_calls(&info);
    find_nested_blocks(&info);
    find_float_temporaries(&info);
  }
  // Global functions are in the dispatch table too, but they have no selector.
  for (int entry : program_->dispatch_table) {
    if (entry < 0 || method_ids_.count(entry) == 0) continue;
    if (Method(program_->bytecodes, entry).selector_offset() >= 0) virtual_entries_.insert(entry);
  }
  compute_pruned_bytecodes(methods);
}

// Native code doesn't need the bytecodes, so the program that goes into the
// snapshot only has the headers of the methods. What used to be the code of a
// method is the original id, so stack traces can use the source map.
void NativeGenerator::compute_pruned_bytecodes(const std::vector<int>& methods) {
  std::set<int> ids(methods.begin(), methods.end());
  for (int entry : program_->dispatch_table) {
    if (entry >= 0) ids.insert(entry);
  }
  for (int id : ids) {
    pruned_ids_[id] = pruned_bytecodes_.size();
    uint8* header = program_->bcp_from_absolute_bci(id);
    pruned_bytecodes_.insert(pruned_bytecodes_.end(), header, header + Method::entry_offset());
    for (int i = 0; i < 4; i++) pruned_bytecodes_.push_back((id >> (i * 8)) & 0xff);
  }
}

// Targets of non-local branches don't have a place in the pruned bytecodes.
// They just need to be unique, so they are numbered after the last method.
int NativeGenerator::pruned_branch_target(int target) {
  auto probe = pruned_branch_targets_.find(target);
  if (probe != pruned_branch_targets_.end()) return probe->second;
  int result = pruned_bytecodes_.size() + pruned_branch_targets_.size();
  pruned_branch_targets_[target] = result;
  return result;
}

void NativeGenerator::update_program() {
  for (int i = 0; i < program_->dispatch_table.length(); i++) {
    int entry = program_->dispatch_table[i];
    if (entry >= 0) program_->dispatch_table[i] = pruned_ids_.at(entry);
  }
  // The lazily initialized globals know the id of their initializer.
  program_->set_heap_writable(true);
  int initializer_class_id = Smi::value(program_->lazy_initializer_class_id());
  for (int i = 0; i < program_->global_variables.length(); i++) {
    Object* value = program_->global_variables.at(i);
    if (!is_instance(value)) continue;
    Instance* instance = Instance::cast(value);
    if (Smi::value(instance->class_id()) != initializer_class_id) continue;
    instance->at_put_no_write_barrier(0, Smi::from(pruned_ids_.at(Smi::value(instance->at(0)))));
  }
  program_->set_heap_writable(false);
  uint8* bytes = unvoid_cast<uint8*>(malloc(pruned_bytecodes_.size()));
  memcpy(bytes, pruned_bytecodes_.data(), pruned_bytecodes_.size());
  program_->bytecodes = List<uint8>(bytes, pruned_bytecodes_.size());
}

static bool needs_continuation(Opcode opcode) {
  switch (opcode) {
    case LOAD_GLOBAL_VAR_DYNAMIC:
    case LOAD_GLOBAL_VAR_LAZY:
    case LOAD_GLOBAL_VAR_LAZY_WIDE:
    case STORE_GLOBAL_VAR_DYNAMIC:
    case ALLOCATE:
    case ALLOCATE_WIDE:
    case AS_CLASS:
    case AS_CLASS_WIDE:
    case AS_INTERFACE:
    case AS_INTERFACE_WIDE:
    case AS_LOCAL:
    case INVOKE_STATIC:
    case INVOKE_BLOCK:
    case INVOKE_VIRTUAL:
    case INVOKE_VIRTUAL_WIDE:
    case INVOKE_VIRTUAL_GET:
    case INVOKE_VIRTUAL_SET:
    case INVOKE_EQ:
    case INVOKE_LT:
    case INVOKE_GT:
    case INVOKE_LTE:
    case INVOKE_GTE:
    case INVOKE_BIT_OR:
    case INVOKE_BIT_XOR:
    case INVOKE_BIT_AND:
    case INVOKE_BIT_SHL:
    case INVOKE_BIT_SHR:
    case INVOKE_BIT_USHR:
    case INVOKE_ADD:
    case INVOKE_SUB:
    case INVOKE_MUL:
    case INVOKE_DIV:
    case INVOKE_MOD:
    case INVOKE_AT:
    case INVOKE_AT_PUT:
    case INVOKE_SIZE:
    case PRIMITIVE:
    case UNWIND:
    case HALT:
      return true;
    default:
      return false;
  }
}

bool NativeGenerator::is_smi_type(TypeSet type) const {
  if (type.is_block()) return false;
  int words = TypeSet::words_per_type(program_);
  return type.size(words) == 1 && type.contains(Smi::value(program_->smi_class_id()));
}

bool NativeGenerator::is_int_type(TypeSet type) const {
  if (type.is_block()) return false;
  int words = TypeSet::words_per_type(program_);
  int count = type.contains(Smi::value(program_->smi_class_id())) ? 1 : 0;
  if (type.contains(Smi::value(program_->large_integer_class_id()))) count++;
  return count > 0 && type.size(words) == count;
}

NativeGenerator::Operands NativeGenerator::operands(uint8* bcp) const {
  Operands result;
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (input.size() != 2 || input[0].is_block() || input[1].is_block()) return result;
  unsigned smi_id = Smi::value(program_->smi_class_id());
  result.left_is_smi = is_smi_type(input[0]);
  result.right_is_smi = is_smi_type(input[1]);
  result.can_be_smis = input[0].contains(smi_id) && input[1].contains(smi_id);
  result.are_ints = is_int_type(input[0]) && is_int_type(input[1]);
  unsigned double_id = Smi::value(program_->double_class_id());
  int words_per_type = TypeSet::words_per_type(program_);
  auto is_float = [&](TypeSet type) { return type.size(words_per_type) == 1 && type.contains(double_id); };
  result.are_floats = is_float(input[0]) && is_float(input[1]);
  result.can_be_floats = input[0].contains(double_id) && input[1].contains(double_id);
  // Integers take up two of the classes. That leaves room for null or a float.
  static const int LIKELY_TYPES = 3;
  int words = TypeSet::words_per_type(program_);
  result.is_likely = input[0].size(words) <= LIKELY_TYPES && input[1].size(words) <= LIKELY_TYPES;
  return result;
}

std::string NativeGenerator::smi_check(const Operands& operands, const std::string& left, const std::string& right) const {
  if (operands.are_smis()) return "";
  if (operands.left_is_smi) return "native_is_smi(" + right + ")";
  if (operands.right_is_smi) return "native_is_smi(" + left + ")";
  return "native_are_smis(" + left + ", " + right + ")";
}

// These operations cannot fail or call anything if they are working
// on integers, so they are done right where they are and they need no
// continuation. Arithmetic can overflow and the results must be allocated.
bool NativeGenerator::stays_in_block(uint8* bcp) const {
  switch (static_cast<Opcode>(*bcp)) {
    case INVOKE_EQ:
    case INVOKE_LT:
    case INVOKE_GT:
    case INVOKE_LTE:
    case INVOKE_GTE:
      return operands(bcp).are_ints || operands(bcp).are_floats;
    case INVOKE_ADD:
    case INVOKE_SUB:
    case INVOKE_MUL:
      // The slow case is a plain call, because no Toit code has to run.
      return operands(bcp).are_ints || operands(bcp).are_floats;
    case INVOKE_DIV:
      return operands(bcp).are_floats;
    case INVOKE_BIT_OR:
    case INVOKE_BIT_XOR:
    case INVOKE_BIT_AND:
      return operands(bcp).are_smis();
    case INVOKE_VIRTUAL_GET:
    case INVOKE_VIRTUAL_SET: {
      // A receiver that can be null needs a way out of the block.
      bool can_be_null = false;
      if (accessor_field(bcp, &can_be_null) >= 0 && !can_be_null) return true;
      return leaf_target(bcp) >= 0;
    }
    case INVOKE_STATIC:
    case INVOKE_VIRTUAL:
      return leaf_target(bcp) >= 0;
    default:
      return false;
  }
}

// Returns the field if all methods the types say we can get to at
// this virtual getter or setter access the same field. Returns -1 otherwise.
int NativeGenerator::accessor_field(uint8* bcp, bool* can_be_null) const {
  bool is_getter = static_cast<Opcode>(*bcp) == INVOKE_VIRTUAL_GET;
  int arity = is_getter ? 1 : 2;
  int selector_offset = Utils::read_unaligned_uint16(bcp + 1);
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (static_cast<int>(input.size()) != arity || input[0].is_block()) return -1;
  int null_id = Smi::value(program_->null_class_id());
  int result = -1;
  TypeSet::Iterator it(input[0], TypeSet::words_per_type(program_));
  while (it.has_next()) {
    int id = it.next();
    int index = id + selector_offset;
    int entry = index < program_->dispatch_table.length() ? program_->dispatch_table[index] : -1;
    bool found = entry >= 0 && method_ids_.count(entry) != 0 &&
        Method(program_->bytecodes, entry).selector_offset() == selector_offset;
    if (!found) {
      if (id != null_id) return -1;
      *can_be_null = true;
      continue;
    }
    Method target(program_->bytecodes, entry);
    if (!target.is_field_accessor()) return -1;
    int field = is_getter ? getter_field(target) : setter_field(target);
    if (field < 0 || (result >= 0 && field != result)) return -1;
    result = field;
  }
  return result;
}

int NativeGenerator::getter_field(Method target) const {
  uint8* entry = target.entry();
  if (entry[0] == LOAD_FIELD_LOCAL && entry[2] == RETURN) return entry[1] >> 4;
  if (entry[0] == LOAD_LOCAL_2 && entry[1] == LOAD_FIELD && entry[3] == RETURN) return entry[2];
  return -1;
}

int NativeGenerator::setter_field(Method target) const {
  uint8* entry = target.entry();
  bool matches = entry[0] == LOAD_LOCAL_3 && entry[1] == LOAD_LOCAL_3 &&
      entry[2] == STORE_FIELD && entry[4] == RETURN;
  return matches ? entry[3] : -1;
}

// Accessors are so small that the call would be much bigger than what it calls.
bool NativeGenerator::emit_inlined_accessor(uint8* bcp, uint8* next) {
  auto probe = current_info_->inlined_calls.find(bcp);
  if (probe == current_info_->inlined_calls.end() || probe->second.field < 0) return false;
  int field = probe->second.field;
  bool is_getter = static_cast<Opcode>(*bcp) == INVOKE_VIRTUAL_GET;
  int stack_offset = is_getter ? 0 : 1;
  if (probe->second.can_be_null) {
    int selector_offset = Utils::read_unaligned_uint16(bcp + 1);
    if_unlikely(cat(stack_at(stack_offset), " == c->null_object"), [&] {
      emit_runtime_next("virtual_fallback", next, virtual_key(selector_offset, stack_offset));
    });
  }
  if (is_getter) {
    stack_at_put(0, field_of(stack_at(0), field));
  } else {
    scope([&] {
      line("Object* value = POP();");
      emit_store_field("STACK_AT(0)", field, needs_write_barrier(bcp, 1));
      stack_at_put(0, "value");
    });
  }
  if (ends_block(bcp)) emit_goto(next);
  return true;
}

bool NativeGenerator::ends_block(uint8* bcp) const {
  return needs_continuation(static_cast<Opcode>(*bcp)) && !stays_in_block(bcp);
}

bool NativeGenerator::is_dead_continuation(uint8* bcp, uint8* next) const {
  if (next >= current_end_) return true;
  switch (static_cast<Opcode>(*bcp)) {
    case INVOKE_STATIC:
    case INVOKE_VIRTUAL:
    case INVOKE_VIRTUAL_WIDE:
    case INVOKE_VIRTUAL_GET:
    case INVOKE_VIRTUAL_SET:
      // The other calls can have their continuation used for other things,
      // like the code following a try-block that is run when unwinding.
      return types_->does_not_return(bci(next));
    default:
      return false;
  }
}

static bool is_call(Opcode opcode) {
  if (opcode >= INVOKE_STATIC && opcode <= INVOKE_SIZE) return true;
  switch (opcode) {
    case LOAD_GLOBAL_VAR_LAZY:
    case LOAD_GLOBAL_VAR_LAZY_WIDE:
    case AS_CLASS:
    case AS_CLASS_WIDE:
    case AS_INTERFACE:
    case AS_INTERFACE_WIDE:
    case AS_LOCAL:
      return true;
    default:
      return false;
  }
}

static bool is_terminal(Opcode opcode) {
  switch (opcode) {
    case BRANCH:
    case BRANCH_BACK:
    case THROW:
    case RETURN:
    case RETURN_NULL:
    case NON_LOCAL_RETURN:
    case NON_LOCAL_RETURN_WIDE:
    case NON_LOCAL_BRANCH:
    case INVOKE_STATIC_TAIL:
    case INVOKE_LAMBDA_TAIL:
    case INVOKE_INITIALIZER_TAIL:
    case INTRINSIC_SMI_REPEAT:
    case INTRINSIC_ARRAY_DO:
    case INTRINSIC_HASH_DO:
      return true;
    default:
      return false;
  }
}

// The analysis.

// Non-local branches go to bytecodes in other methods.
void NativeGenerator::find_branch_targets() {
  for (auto& info : methods_) {
    uint8* bcp = info.method.entry();
    while (bcp < info.end) {
      Opcode opcode = static_cast<Opcode>(*bcp);
      if (opcode >= ILLEGAL_END) break;
      if (opcode == NON_LOCAL_BRANCH) branch_targets_.insert(Utils::read_unaligned_uint32(bcp + 2));
      bcp += opcode_length[opcode];
    }
  }
}

// Finds the bytecodes that can run. Code that follows a call that doesn't
// return is often left behind, and it would keep what it calls alive through
// the tables of return addresses.
void NativeGenerator::find_reachable(MethodInfo* info) {
  current_end_ = info->end;
  uint8* entry = info->method.entry();
  std::vector<uint8*> pending = { entry };
  if (program_->has_entry_task() && entry == program_->entry_task().entry()) {
    // Tasks start after the first bytecode.
    pending.push_back(entry + LOAD_NULL_LENGTH);
  }
  for (int target : branch_targets_) {
    uint8* bcp = program_->bcp_from_absolute_bci(target);
    if (bcp >= entry && bcp < info->end) pending.push_back(bcp);
  }
  while (!pending.empty()) {
    uint8* bcp = pending.back();
    pending.pop_back();
    while (bcp < info->end && info->reachable.count(bcp) == 0) {
      Opcode opcode = static_cast<Opcode>(*bcp);
      if (opcode >= ILLEGAL_END) break;
      info->reachable.insert(bcp);
      uint8* next = bcp + opcode_length[opcode];
      if (ends_block(bcp) && is_dead_continuation(bcp, next)) break;
      switch (opcode) {
        case BRANCH_IF_TRUE:
        case BRANCH_IF_FALSE:
        case BRANCH_IF_NOT_NULL:
          pending.push_back(bcp + Utils::read_unaligned_uint16(bcp + 1));
          break;
        case BRANCH_BACK_IF_TRUE:
        case BRANCH_BACK_IF_FALSE:
        case BRANCH_BACK_IF_NOT_NULL:
          pending.push_back(bcp - Utils::read_unaligned_uint16(bcp + 1));
          break;
        case BRANCH:
          pending.push_back(bcp + Utils::read_unaligned_uint16(bcp + 1));
          break;
        case BRANCH_BACK:
          pending.push_back(bcp - Utils::read_unaligned_uint16(bcp + 1));
          break;
        default:
          break;
      }
      if (is_terminal(opcode)) break;
      bcp = next;
    }
  }
}

static bool is_comparison(Opcode opcode) {
  return opcode == INVOKE_EQ || opcode == INVOKE_LT || opcode == INVOKE_LTE ||
      opcode == INVOKE_GT || opcode == INVOKE_GTE;
}

// The fast path of a comparison that can also take a slow path doesn't need
// to create a boolean if the next bytecode branches on it.
bool NativeGenerator::branches_after_comparison(uint8* next) const {
  Opcode opcode = static_cast<Opcode>(*next);
  return next < current_end_ && (opcode == BRANCH_IF_TRUE || opcode == BRANCH_IF_FALSE);
}

// Finds the basic blocks of the code that can run, and how they are entered.
void NativeGenerator::find_blocks(MethodInfo* info) {
  current_end_ = info->end;
  auto& blocks = info->blocks;
  auto entered_from = [&](uint8* target, uint8* from) {
    BasicBlock& block = blocks[target];
    block.entries++;
    block.last_entry = from;
  };
  auto has_label = [&](uint8* target) { blocks[target].has_label = true; };

  uint8* entry = info->method.entry();
  has_label(entry);
  if (program_->has_entry_task() && entry == program_->entry_task().entry()) {
    // Tasks start after the first bytecode.
    has_label(entry + LOAD_NULL_LENGTH);
  }
  for (int target : branch_targets_) {
    uint8* bcp = program_->bcp_from_absolute_bci(target);
    if (bcp >= entry && bcp < info->end) has_label(bcp);
  }

  for (uint8* bcp : info->reachable) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    uint8* next = bcp + opcode_length[opcode];
    if (ends_block(bcp) && !is_terminal(opcode)) {
      if (is_dead_continuation(bcp, next)) {
        dead_continuations_.insert(next);
      } else {
        has_label(next);
      }
      if (is_call(opcode)) return_points_.insert(next);
      if (is_comparison(opcode) && branches_after_comparison(next)) {
        // The fast path goes where the branch goes.
        uint8* target = next + Utils::read_unaligned_uint16(next + 1);
        entered_from(target, bcp);
        entered_from(next + BRANCH_IF_TRUE_LENGTH, bcp);
      }
    }
    if (opcode == INTRINSIC_SMI_REPEAT || opcode == INTRINSIC_ARRAY_DO || opcode == INTRINSIC_HASH_DO) {
      // The blocks return to the intrinsic.
      has_label(bcp);
      return_points_.insert(bcp);
    }
    switch (opcode) {
      case BRANCH_IF_TRUE:
      case BRANCH_IF_FALSE:
      case BRANCH_IF_NOT_NULL:
        blocks[next];  // The fall-through is found below.
        [[fallthrough]];
      case BRANCH:
        entered_from(bcp + Utils::read_unaligned_uint16(bcp + 1), bcp);
        break;
      case BRANCH_BACK_IF_TRUE:
      case BRANCH_BACK_IF_FALSE:
      case BRANCH_BACK_IF_NOT_NULL:
        blocks[next];  // The fall-through is found below.
        [[fallthrough]];
      case BRANCH_BACK:
        entered_from(bcp - Utils::read_unaligned_uint16(bcp + 1), bcp);
        break;
      default:
        break;
    }
  }

  // A call that doesn't return still passes its return address.
  for (uint8* bcp : dead_continuations_) {
    auto probe = blocks.find(bcp);
    if (probe != blocks.end()) probe->second.has_label = true;
  }
  for (auto& it : blocks) dead_continuations_.erase(it.first);

  BasicBlock* current = null;
  bool can_continue = false;
  uint8* last = null;
  for (uint8* bcp : info->reachable) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    uint8* next = bcp + opcode_length[opcode];
    auto probe = blocks.find(bcp);
    if (probe != blocks.end()) {
      if (can_continue) {
        current->falls_through = true;
        entered_from(bcp, last);
      }
      current = &probe->second;
    }
    current->end = next;
    current->last = bcp;
    bool is_branch = opcode == BRANCH || opcode == BRANCH_BACK;
    can_continue = !is_terminal(opcode) && !ends_block(bcp) && !is_branch;
    last = bcp;
    if (can_continue && is_comparison(opcode) && branches_after_comparison(next) && blocks.count(next) == 0) {
      info->merged_comparisons.insert(bcp);
    }
  }
  if (can_continue) current->falls_through = true;
  // Targets that are never reached have no code.
  for (auto it = blocks.begin(); it != blocks.end();) {
    it = it->second.last == null ? blocks.erase(it) : std::next(it);
  }
  find_successors(info);
}

void NativeGenerator::find_successors(MethodInfo* info) {
  for (auto& it : info->blocks) {
    BasicBlock& block = it.second;
    uint8* last = block.last;
    Opcode opcode = static_cast<Opcode>(*last);
    uint8* next = last + opcode_length[opcode];
    auto add = [&](uint8* target) {
      if (info->blocks.count(target) != 0) block.successors.push_back(target);
    };
    switch (opcode) {
      case BRANCH_IF_TRUE:
      case BRANCH_IF_FALSE:
      case BRANCH_IF_NOT_NULL:
      case BRANCH:
        add(last + Utils::read_unaligned_uint16(last + 1));
        break;
      case BRANCH_BACK_IF_TRUE:
      case BRANCH_BACK_IF_FALSE:
      case BRANCH_BACK_IF_NOT_NULL:
      case BRANCH_BACK:
        add(last - Utils::read_unaligned_uint16(last + 1));
        break;
      default:
        break;
    }
    bool is_jump = opcode == BRANCH || opcode == BRANCH_BACK;
    if (!is_jump && !(is_terminal(opcode) && !block.falls_through)) add(next);
  }
}

// Code that can only be reached from one place doesn't need its own function.
// Hot and cold code is compiled differently, so that has to be kept apart.
void NativeGenerator::find_nested_blocks(MethodInfo* info) {
  for (auto& it : info->blocks) {
    uint8* begin = it.first;
    BasicBlock& block = it.second;
    block.is_nested = !block.has_label && block.entries == 1 && block.last_entry < begin &&
        is_hot_code(*info, begin) == is_hot_code(*info, block.last_entry);
  }
}

// The body of a loop is what can get to the branch back without going through
// the head of the loop, which leaves out the paths that leave the loop.
void NativeGenerator::find_hot_code(MethodInfo* info) {
  info->is_hot = false;
  if (Flags::native_all_cold) return;
  for (uint8* bcp : info->reachable) {
    bool is_call_to_self = *bcp == INVOKE_STATIC &&
        program_->dispatch_table[Utils::read_unaligned_uint16(bcp + 1)] == method_id(info->method);
    if (is_call_to_self) info->is_hot = true;
    // The loops of 'repeat' and 'do' are in these methods.
    if (*bcp == INTRINSIC_SMI_REPEAT || *bcp == INTRINSIC_ARRAY_DO || *bcp == INTRINSIC_HASH_DO) {
      info->is_hot = true;
      info->has_loops = true;
    }
  }
  std::map<uint8*, std::vector<uint8*>> predecessors;
  for (auto& it : info->blocks) {
    for (uint8* successor : it.second.successors) predecessors[successor].push_back(it.first);
  }
  for (auto& it : info->blocks) {
    for (uint8* head : it.second.successors) {
      if (head > it.first) continue;
      info->has_loops = true;
      std::set<uint8*> body = { head };
      std::vector<uint8*> pending = { it.first };
      while (!pending.empty()) {
        uint8* bcp = pending.back();
        pending.pop_back();
        if (!body.insert(bcp).second) continue;
        for (uint8* predecessor : predecessors[bcp]) pending.push_back(predecessor);
      }
      for (uint8* bcp : body) info->blocks.at(bcp).is_hot = true;
    }
  }
}

// The result of an operation on floats is a new object, no matter which path
// it takes. Until something else gets a reference to it, the only reference is
// the one on the stack, so the operation that consumes it can reuse the object.
// This follows the top of the stack through code without branches and it
// forgets everything at any bytecode it doesn't know about.
void NativeGenerator::find_float_temporaries(MethodInfo* info) {
  std::vector<bool> stack;  // Whether the elements are temporaries. Below it, nothing is.
  uint8* continuation = null;
  auto pop = [&](int count) {
    while (count-- > 0 && !stack.empty()) stack.pop_back();
  };
  auto load_local = [&](int index) {
    int size = static_cast<int>(stack.size());
    if (index < size) stack[size - 1 - index] = false;
    stack.push_back(false);
  };
  for (uint8* bcp : info->reachable) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    auto block = info->blocks.find(bcp);
    if (block != info->blocks.end()) {
      // Only the operation that leaves a temporary can get to its continuation.
      bool is_target = branch_targets_.count(bci(bcp)) != 0;
      if (bcp != continuation || block->second.entries != 0 || is_target) stack.clear();
    }
    continuation = null;
    switch (opcode) {
      case LOAD_LOCAL:
        load_local(bcp[1]);
        break;
      case LOAD_LOCAL_WIDE:
        load_local(Utils::read_unaligned_uint16(bcp + 1));
        break;
      case LOAD_LOCAL_0:
      case LOAD_LOCAL_1:
      case LOAD_LOCAL_2:
      case LOAD_LOCAL_3:
      case LOAD_LOCAL_4:
      case LOAD_LOCAL_5:
        load_local(opcode - LOAD_LOCAL_0);
        break;
      case LOAD_LITERAL:
      case LOAD_LITERAL_WIDE:
      case LOAD_NULL:
      case LOAD_SMI_0:
      case LOAD_SMI_1:
      case LOAD_SMI_U8:
      case LOAD_SMI_U16:
      case LOAD_SMI_U32:
        stack.push_back(false);
        break;
      case LOAD_FIELD:
      case LOAD_FIELD_WIDE:
        pop(1);
        stack.push_back(false);
        break;
      case POP:
        pop(bcp[1]);
        break;
      case POP_1:
        pop(1);
        break;
      case INVOKE_ADD:
      case INVOKE_SUB:
      case INVOKE_MUL:
      case INVOKE_DIV: {
        if (!operands(bcp).are_floats) {
          stack.clear();
          break;
        }
        int size = static_cast<int>(stack.size());
        bool right_is_temporary = size >= 1 && stack[size - 1];
        bool left_is_temporary = size >= 2 && stack[size - 2];
        if (left_is_temporary) {
          info->reused_floats[bcp] = 1;
        } else if (right_is_temporary) {
          info->reused_floats[bcp] = 0;
        }
        pop(2);
        stack.push_back(true);
        continuation = bcp + opcode_length[opcode];
        break;
      }
      default:
        stack.clear();
        break;
    }
  }
}

// Decides which calls to replace with the code of what they call. It's a
// question of size, so it's worth more in hot code.
void NativeGenerator::find_inlined_calls(MethodInfo* info) {
  for (uint8* bcp : info->reachable) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    bool is_accessor_call = opcode == INVOKE_VIRTUAL_GET || opcode == INVOKE_VIRTUAL_SET;
    if (!is_accessor_call && opcode != INVOKE_VIRTUAL && opcode != INVOKE_STATIC) continue;
    if (is_accessor_call) {
      bool can_be_null = false;
      int field = accessor_field(bcp, &can_be_null);
      // It's smaller to let the dispatch table deal with null in cold code.
      if (field >= 0 && (!can_be_null || is_hot_code(*info, bcp))) {
        info->inlined_calls[bcp] = { field, can_be_null, -1 };
        continue;
      }
    }
    int leaf = leaf_target(bcp);
    if (leaf >= 0) {
      info->inlined_calls[bcp] = { -1, false, leaf };
      info->has_inlined_leaf = true;
    }
  }
}

// The bodies of 'repeat' and 'do' are blocks, but they are as hot as any loop.
// The last block loaded before a call is the one that is passed to it.
void NativeGenerator::find_hot_blocks() {
  if (Flags::native_all_cold) return;
  std::map<int, const MethodInfo*> by_id;
  for (auto& info : methods_) by_id[method_id(info.method)] = &info;
  std::vector<int> hot;
  for (auto& info : methods_) {
    int block = -1;
    uint8* bcp = info.method.entry();
    while (bcp < info.end) {
      Opcode opcode = static_cast<Opcode>(*bcp);
      if (opcode >= ILLEGAL_END) break;
      if (opcode == LOAD_METHOD) {
        block = Utils::read_unaligned_uint32(bcp + 1);
      } else if (block >= 0 && is_call(opcode)) {
        std::set<int> targets;
        bool can_be_null = false;
        if (opcode == INVOKE_STATIC) {
          targets.insert(program_->dispatch_table[Utils::read_unaligned_uint16(bcp + 1)]);
        } else if (opcode == INVOKE_VIRTUAL) {
          find_targets(bcp, bcp[1], Utils::read_unaligned_uint16(bcp + 2), &targets, &can_be_null);
        }
        for (int target : targets) {
          auto probe = by_id.find(target);
          if (probe != by_id.end() && probe->second->has_loops) hot.push_back(block);
        }
        block = -1;
      }
      bcp += opcode_length[opcode];
    }
  }
  for (auto& info : methods_) {
    if (std::find(hot.begin(), hot.end(), method_id(info.method)) != hot.end()) info.is_hot = true;
  }
}

bool NativeGenerator::is_hot_code(const MethodInfo& info, uint8* bcp) const {
  if (info.is_hot) return true;
  auto probe = info.blocks.upper_bound(bcp);
  return probe != info.blocks.begin() && std::prev(probe)->second.is_hot;
}

const char* NativeGenerator::attributes(const MethodInfo& info, uint8* bcp) const {
  return is_hot_code(info, bcp) ? "" : "NATIVE_COLD ";
}

// Emitting the program.

// The tables are written in assembler, which needs to know the symbols.
void NativeGenerator::declare(const char* attributes, const std::string& name) {
  line(cat("static ", attributes, "void ", name, "(NATIVE_PARAMS) __asm__(\"", name, "\") NATIVE_ON_STACK;"));
}

void NativeGenerator::emit_declarations() {
  for (auto& info : methods_) {
    uint8* bcp = info.method.entry();
    while (bcp < info.end) {
      Opcode opcode = static_cast<Opcode>(*bcp);
      if (opcode >= ILLEGAL_END) break;
      if (opcode == LOAD_METHOD) {
        int id = Utils::read_unaligned_uint32(bcp + 1);
        Method target(program_->bytecodes, id);
        if (target.is_block_method() && method_ids_.count(id) == 0) dead_blocks_.insert(id);
      }
      bcp += opcode_length[opcode];
    }
  }
  for (auto& info : methods_) {
    int id = method_id(info.method);
    declare(attributes(info, info.method.entry()), method_label(id));
    if (has_virtual_entry(id)) {
      declare(attributes(info, info.method.entry()), virtual_label(id));
    }
    if (info.method.is_block_method()) declare("", block_entry_label(id));
    current_end_ = info.end;
    for (auto& it : info.blocks) {
      if (!it.second.is_nested) declare(attributes(info, it.first), label(it.first));
    }
  }
  for (int id : dead_blocks_) declare("", block_entry_label(id));
  for (uint8* bcp : dead_continuations_) declare("", label(bcp));
  line("");
}

struct PrimitiveInfo {
  const char* name;
  int arity;
};

#define PRIMITIVE_INFO(name, arity) { #name, arity },
#define MODULE_INFO(name, entries) static const PrimitiveInfo name##_infos[] = { entries(PRIMITIVE_INFO) { null, 0 } };
MODULES(MODULE_INFO)
#undef MODULE_INFO
#undef PRIMITIVE_INFO

#define MODULE_NAME(name, entries) #name,
static const char* const module_names[] = { MODULES(MODULE_NAME) };
#undef MODULE_NAME
#define MODULE_INFOS(name, entries) name##_infos,
static const PrimitiveInfo* const module_infos[] = { MODULES(MODULE_INFOS) };
#undef MODULE_INFOS

static std::string primitive_name(int module, int index) {
  return "toit::" + std::string(module_names[module]) + "_module::p_" + module_infos[module][index].name;
}

// The primitives are called directly, so the linker can see which ones are
// used and drop the rest of the runtime. See native_module_stubs.cc for the
// primitives that a platform doesn't have.
void NativeGenerator::emit_primitive_declarations() {
  std::set<std::pair<int, int>> primitives;
  for (auto& info : methods_) {
    for (uint8* bcp : info.reachable) {
      if (*bcp == PRIMITIVE) primitives.insert({ bcp[1], Utils::read_unaligned_uint16(bcp + 2) });
    }
  }
  line("namespace toit {");
  int current_module = -1;
  for (auto& it : primitives) {
    if (it.first != current_module) {
      if (current_module >= 0) line(cat("}  // namespace ", module_names[current_module], "_module"));
      current_module = it.first;
      line(cat("namespace ", module_names[current_module], "_module {"));
    }
    line(cat("Object* p_", module_infos[it.first][it.second].name, "(Process*, Object**);"));
  }
  if (current_module >= 0) line(cat("}  // namespace ", module_names[current_module], "_module"));
  line("}  // namespace toit");
  line("");
}

void NativeGenerator::emit_tables() {
  List<int32> dispatch_table = program_->dispatch_table;
  line("static const NativeFn vtable[] = {");
  for (int i = 0; i < dispatch_table.length(); i++) {
    int entry = dispatch_table[i];
    bool valid = entry >= 0 && has_virtual_entry(entry);
    this->entry(valid ? virtual_label(entry) : std::string("NativeRuntime::virtual_fallback"));
  }
  line("};");
  line("");
  std::map<int, std::string> entries;
  current_end_ = null;
  for (auto& info : methods_) entries[pruned_entry(method_id(info.method))] = method_label(info.method);
  if (program_->has_entry_task() && method_ids_.count(method_id(program_->entry_task())) != 0) {
    uint8* task = program_->entry_task().entry() + LOAD_NULL_LENGTH;
    // The place in the pruned method isn't used for anything but finding the code.
    entries[pruned_entry(method_id(program_->entry_task())) + LOAD_NULL_LENGTH] = label(task);
    // The return address of the outermost frame. Traces need the original bci.
    return_points_.insert(task);
  }
  for (int target : branch_targets_) {
    entries[pruned_branch_target(target)] = label(program_->bcp_from_absolute_bci(target));
  }

  std::set<std::string> used;
  for (auto& it : entries) used.insert(it.second);
  for (uint8* bcp : return_points_) used.insert(label(bcp));
  for (auto& name : used) line("NATIVE_USED(" + name + ");");
  line("");

  // These are the tables described in native_abi.h.
  line("__asm__(NATIVE_TABLE_SECTION R\"__toit__(");
  line(".p2align 2");
  line("toit_native_entries:");
  for (auto& it : entries) line(cat(".long ", it.first, ", ", it.second, " - ."));
  line("toit_native_returns:");
  for (uint8* bcp : return_points_) line(cat(".long ", label(bcp), " - ."));
  line("toit_native_return_deltas:");
  int last_bci = 0;
  for (uint8* bcp : return_points_) {
    int delta = bci(bcp) - last_bci;
    last_bci = bci(bcp);
    std::string bytes = ".byte ";
    for (; delta >= 0x80; delta >>= 7) bytes += cat((delta & 0x7f) | 0x80, ", ");
    line(bytes + std::to_string(delta));
  }
  line(".text\n)__toit__\");");
  line("");
  line("extern const NativeEntry entries[] __asm__(\"toit_native_entries\");");
  line("extern const int32_t returns[] __asm__(\"toit_native_returns\");");
  line("extern const uint8_t return_deltas[] __asm__(\"toit_native_return_deltas\");");
  line("");

  // The compiler adds these to the end of the file when the program is done.
  line("namespace {");
  line("extern const bool native_is_system;");
  line("extern const uint8_t native_uuid[];");
  line("extern const uint8_t native_image[];");
  line("extern const int native_image_words;");
  line("extern const uint8_t native_image_ranges[];");
  line("extern const int native_image_ranges_size;");
  line("extern const uint8_t native_bundle[];");
  line("extern const int native_bundle_size;");
  line("}  // namespace");
  line("");
  line("static const NativeProgram native_program = {");
  entry("NATIVE_ABI");
  entry(cat(native_fingerprint(pruned_bytecodes_.data(), pruned_bytecodes_.size()), "u"));
  entry(std::to_string(pruned_bytecodes_.size()));
  entry("entries");
  entry(std::to_string(entries.size()));
  entry("returns");
  entry("return_deltas");
  entry(std::to_string(return_points_.size()));
  entry("native_uuid");
  entry("native_image");
  entry("native_image_words * static_cast<int>(sizeof(intptr_t))");
  entry("reinterpret_cast<const int32_t*>(native_image_ranges)");
  entry("native_image_ranges_size / static_cast<int>(2 * sizeof(int32_t))");
  entry("native_bundle");
  entry("native_bundle_size");
  entry("native_is_system");
  line("};");
  line("");
  line("static int registered = NativeRuntime::register_program(&native_program);");
}

std::string NativeGenerator::generate() {
  line("// Generated by the Toit compiler.");
  line(cat("#define NATIVE_ABI ", NATIVE_ABI, "u"));
  out_ << NATIVE_ABI_SOURCE;
  line("");
  line("using namespace toit;");
  line("");
  line(cat("static const unsigned SMI_ID = ", Smi::value(program_->smi_class_id()), ";"));
  line("");
  emit_primitive_declarations();
  emit_declarations();
  emit_tables();
  line("");
  // The thunks are found while emitting the methods, but must be declared first.
  std::string declarations = out_.str();
  out_.str("");
  for (auto& info : methods_) emit_method(info);
  std::string body = out_.str();
  out_.str("");
  out_ << declarations;
  for (auto& thunk : virtual_thunks_) line("static void " + thunk_label(thunk) + "(NATIVE_PARAMS);");
  line("");
  out_ << body;
  for (int id : dead_blocks_) emit_block_entry(Method(program_->bytecodes, id), true);
  for (uint8* bcp : dead_continuations_) {
    function(label(bcp), [&] {
      tail_call("NativeRuntime::illegal");
    });
  }
  for (auto& thunk : virtual_thunks_) {
    function(thunk_label(thunk), [&] {
      int selector_offset = std::get<0>(thunk);
      int stack_offset = std::get<1>(thunk);
      std::string table_entry = cat("vtable[", class_id_expression(stack_at(stack_offset), std::get<2>(thunk)), " + ", selector_offset, "]");
      tail_call(table_entry, "x", virtual_key(selector_offset, stack_offset), "t");
    });
  }
  update_program();
  return out_.str();
}

// Blocks can be called with too many arguments. The caller leaves the
// number of arguments in y and the return address in x. A block that is
// dead can still be called, because it is the block that checks the
// arguments, so it gets the check without the code of the block.
void NativeGenerator::emit_block_entry(Method method, bool is_dead) {
  int id = method_id(method);
  function(block_entry_label(id), [&] {
    // Calls with too few arguments fail, and calls with too many are rare.
    if_unlikely(cat("y != ", method.arity()), [&] {
      emit_runtime(is_dead ? "block_failure" : "block_arguments", "x", cat("(", pruned_id(id), " << 8) | y"));
    });
    if (is_dead) {
      tail_call("NativeRuntime::illegal");
    } else {
      emit_frame("NATIVE_OBJECT(x)", is_hot_code(*current_info_, method.entry()));
      tail_call(method_label(id));
    }
  });
}

// The most stack an inlined leaf can use. It has the room for a frame and
// each of its opcodes pushes at most one value.
static const int INLINED_STACK_USE = 8;

// Emitting methods and blocks.

void NativeGenerator::emit_method(const MethodInfo& info) {
  Method method = info.method;
  int id = method_id(method);
  current_end_ = info.end;
  current_info_ = &info;
  if (method.is_block_method()) emit_block_entry(method, false);
  if (has_virtual_entry(id)) {
    // The rows of the dispatch table overlap, so a receiver that doesn't have
    // the method can end up here. This is where the entry in the table is
    // checked, which leaves the call sites with nothing but the jump.
    function(virtual_label(id), [&] {
      if_unlikely(cat("y != ", virtual_key(method.selector_offset(), method.arity() - 1)), [&] {
        spill();
        tail_call("NativeRuntime::virtual_fallback");
      });
      emit_frame("NATIVE_OBJECT(x)", is_hot_code(info, method.entry()));
      tail_call(method_label(id));
    });
  }
  function(method_label(id), [&] {
    if_unlikely(cat("NativeRuntime::needs_stack_check(c, sp, ", (method.max_height() + (info.has_inlined_leaf ? INLINED_STACK_USE : 0) + 1), ")"), [&] {
      spill();
      tail_call("NativeRuntime::stack_overflow", "x", pruned_id(id), "t");
    });
    tail_call(label(method.entry()));
  });

  for (auto& it : info.blocks) {
    if (it.second.is_nested) continue;
    function(label(it.first), [&] { emit_block(info, it.first); });
  }
}

void NativeGenerator::emit_block(const MethodInfo& info, uint8* begin) {
  const BasicBlock& block = info.blocks.at(begin);
  uint8* bcp = begin;
  while (bcp < block.end) {
    bool is_merged = info.merged_comparisons.count(bcp) != 0;
    emit_opcode(info, bcp);
    bcp += opcode_length[*bcp];
    if (is_merged) bcp += opcode_length[*bcp];
  }
  flush_stack();
  if (!block.falls_through) return;
  if (info.blocks.count(block.end) != 0) {
    emit_goto(block.end);
  } else {
    tail_call("NativeRuntime::illegal");
  }
}

// Pushes the two words of a frame. The callee is likely to load its arguments
// right away, so in hot code they are kept out of the paired store with the frame.
void NativeGenerator::emit_frame(const std::string& return_address, bool is_hot) {
  if (is_hot) line("NATIVE_SPLIT_STORES();");
  push(return_address);
  if (is_hot) line("NATIVE_SPLIT_STORES();");
  push("NATIVE_FRAME_MARKER");
}

void NativeGenerator::emit_goto(uint8* target) {
  auto probe = current_info_->blocks.find(target);
  if (probe != current_info_->blocks.end() && probe->second.is_nested) {
    nesting_++;
    emit_block(*current_info_, target);
    nesting_--;
  } else {
    tail_call(label(target));
  }
}

void NativeGenerator::emit_call(int id, uint8* next) {
  emit_frame(return_address(label(next)), is_hot_site(next));
  tail_call(method_label(id));
}

// Leaves the result of the condition on the stack if it worked. Otherwise, the
// code continues with what comes next, which is the slow path.
void NativeGenerator::emit_result_if(const std::string& condition, int count, uint8* next) {
  scope([&] {
    line("Object* result = nullptr;");
    if_likely(condition, [&] {
      drop_push(count, "result");
      emit_goto(next);
    });
  });
}

void NativeGenerator::emit_runtime_next(const char* helper, uint8* next, word y) {
  emit_runtime(helper, address_of(label(next)), y);
}

void NativeGenerator::emit_virtual(uint8* bcp, uint8* next, int stack_offset, int selector_offset) {
  if (emit_direct_calls(bcp, next, stack_offset, selector_offset)) return;
  // Most receivers cannot be smis, so there is no reason to check for it.
  std::vector<TypeSet> input = types_->input(bci(bcp));
  bool can_be_smi = static_cast<int>(input.size()) != stack_offset + 1 ||
      input[0].is_block() ||
      input[0].contains(Smi::value(program_->smi_class_id()));
  std::string address = address_of(label(next));
  if (!is_hot_site(bcp)) {
    // Sites that aren't hot share the code for the lookup.
    auto thunk = std::make_tuple(selector_offset, stack_offset, can_be_smi);
    virtual_thunks_.insert(thunk);
    tail_call(thunk_label(thunk), address, "y", "t");
    return;
  }
  std::string receiver = stack_at(stack_offset);
  tail_call(cat("vtable[", class_id_expression(receiver, can_be_smi), " + ", selector_offset, "]"), address, virtual_key(selector_offset, stack_offset), "t");
}

// Finds the methods the receivers of a virtual call can get to. Returns false
// if there are receivers other than null that don't have the method.
bool NativeGenerator::find_targets(uint8* bcp, int stack_offset, int selector_offset,
                                   std::set<int>* targets, bool* can_be_null) const {
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (static_cast<int>(input.size()) != stack_offset + 1 || input[0].is_block()) return false;
  int null_id = Smi::value(program_->null_class_id());
  TypeSet::Iterator it(input[0], TypeSet::words_per_type(program_));
  while (it.has_next()) {
    int id = it.next();
    int index = id + selector_offset;
    int entry = index < program_->dispatch_table.length() ? program_->dispatch_table[index] : -1;
    if (entry >= 0 && method_ids_.count(entry) != 0 &&
        Method(program_->bytecodes, entry).selector_offset() == selector_offset) {
      targets->insert(entry);
    } else if (id == null_id) {
      *can_be_null = true;
    } else {
      return false;
    }
  }
  return true;
}

// The types often leave us with a single method that can be called, even if
// there are many receiver classes. Going directly to it is smaller and
// doesn't need the dispatch table or the check of the selector.
bool NativeGenerator::emit_direct_calls(uint8* bcp, uint8* next, int stack_offset, int selector_offset) {
  std::set<int> targets;
  bool can_be_null = false;
  if (!find_targets(bcp, stack_offset, selector_offset, &targets, &can_be_null)) return false;
  if (targets.size() != 1) return false;
  // The dispatch table deals with null without any extra code at the call site.
  // That's slower, but smaller, because the sites can share the lookup.
  if (can_be_null && !is_hot_site(bcp)) return false;

  std::string receiver = stack_at(stack_offset);
  if (can_be_null) {
    if_unlikely(cat(receiver, " == c->null_object"), [&] {
      emit_runtime_next("virtual_fallback", next, virtual_key(selector_offset, stack_offset));
    });
  }
  emit_call(*targets.begin(), next);
  return true;
}

// A leaf is a short method that doesn't do anything that can call, allocate or
// throw, so it doesn't need a frame. The bytecode compiler inlines many of
// these, but not when the target depends on the propagated types.
bool NativeGenerator::is_leaf(Method method) const {
  static const int MAX_OPCODES = 6;
  if (!method.is_normal_method() && !method.is_field_accessor()) return false;
  uint8* bcp = method.entry();
  for (int i = 0; i < MAX_OPCODES; i++) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    switch (opcode) {
      case LOAD_LOCAL:
      case LOAD_LOCAL_WIDE:
      case LOAD_LOCAL_0:
      case LOAD_LOCAL_1:
      case LOAD_LOCAL_2:
      case LOAD_LOCAL_3:
      case LOAD_LOCAL_4:
      case LOAD_LOCAL_5:
      case POP_LOAD_LOCAL:
      case STORE_LOCAL:
      case STORE_LOCAL_POP:
      case LOAD_FIELD:
      case LOAD_FIELD_WIDE:
      case LOAD_FIELD_LOCAL:
      case POP_LOAD_FIELD_LOCAL:
      case STORE_FIELD:
      case STORE_FIELD_WIDE:
      case STORE_FIELD_POP:
      case LOAD_LITERAL:
      case LOAD_LITERAL_WIDE:
      case LOAD_NULL:
      case LOAD_SMI_0:
      case LOAD_SMI_1:
      case LOAD_SMI_U8:
      case LOAD_SMI_U16:
      case LOAD_SMI_U32:
      case POP:
      case POP_1:
        bcp += opcode_length[opcode];
        break;
      case RETURN:
      case RETURN_NULL:
        return true;
      default:
        return false;
    }
  }
  return false;
}

// Returns the method to inline at a call or -1.
int NativeGenerator::leaf_target(uint8* bcp) const {
  int entry = -1;
  std::set<int> targets;
  bool can_be_null = false;
  bool found = true;
  switch (static_cast<Opcode>(*bcp)) {
    case INVOKE_STATIC:
      entry = program_->dispatch_table[Utils::read_unaligned_uint16(bcp + 1)];
      break;
    case INVOKE_VIRTUAL:
      found = find_targets(bcp, bcp[1], Utils::read_unaligned_uint16(bcp + 2), &targets, &can_be_null);
      break;
    case INVOKE_VIRTUAL_GET:
      found = find_targets(bcp, 0, Utils::read_unaligned_uint16(bcp + 1), &targets, &can_be_null);
      break;
    case INVOKE_VIRTUAL_SET:
      found = find_targets(bcp, 1, Utils::read_unaligned_uint16(bcp + 1), &targets, &can_be_null);
      break;
    default:
      return -1;
  }
  if (!found || can_be_null || targets.size() > 1) return -1;
  if (targets.size() == 1) entry = *targets.begin();
  if (entry < 0 || method_ids_.count(entry) == 0) return -1;
  return is_leaf(Method(program_->bytecodes, entry)) ? entry : -1;
}

// The code of the method works as it does in the method itself if we leave
// room for the frame. Nothing looks at that part of the stack, because
// leaves can't call anything or let the garbage collector run.
bool NativeGenerator::emit_inlined_leaf(const MethodInfo& info, uint8* bcp) {
  auto probe = current_info_->inlined_calls.find(bcp);
  if (probe == current_info_->inlined_calls.end() || probe->second.leaf < 0) return false;
  int entry = probe->second.leaf;
  // Leaves room for the frame.
  for (int i = 0; i < Interpreter::FRAME_SIZE; i++) push("nullptr");
  uint8* leaf = Method(program_->bytecodes, entry).entry();
  while (*leaf != RETURN && *leaf != RETURN_NULL) {
    emit_opcode(info, leaf);
    leaf += opcode_length[*leaf];
  }
  flush_stack();
  int drop = leaf[1] + Interpreter::FRAME_SIZE + leaf[2];
  if (*leaf == RETURN) {
    scope([&] {
      line("Object* result = STACK_AT(0);");
      drop_push(drop, "result");
    });
  } else {
    drop_push(drop, "c->null_object");
  }
  return true;
}

std::string NativeGenerator::class_id_expression(const std::string& receiver, bool can_be_smi) const {
  if (can_be_smi) return "native_class_id(" + receiver + ", SMI_ID)";
  return "native_heap_class_id(" + receiver + ")";
}

void NativeGenerator::emit_arithmetic(uint8* bcp, uint8* next, Opcode opcode, const char* helper, const char* float_op) {
  Operands info = operands(bcp);
  if (stays_in_block(bcp)) {
    if (info.are_floats) {
      emit_float_operation(bcp, float_op);
    } else {
      emit_int_operation(bcp, opcode, helper);
    }
    return;
  }
  bool is_hot = is_hot_site(bcp);
  bool use_smis = info.can_be_smis && (info.is_likely || is_hot);
  // Boxing the result takes more code than calling the runtime.
  bool use_floats = float_op != null && info.can_be_floats && is_hot;
  if (use_smis || use_floats) {
    int kept = keep_on_top(2);
    std::string left = operand(1, kept);
    std::string right = operand(0, kept);
    auto finish = [&] {
      if (kept == 2) {
        push("result");
      } else {
        drop_push(2 - kept, "result");
      }
      emit_goto(next);
    };
    scope([&] {
      line("Object* result = nullptr;");
      if (use_smis) {
        std::string check = smi_check(info, left, right);
        if (!check.empty()) check += " && ";
        if_likely(cat(check, helper, "(", left, ", ", right, ", &result)"), finish);
      }
      if (use_floats) {
        std::string check = info.are_floats ? "" : cat("native_are_doubles(", left, ", ", right, ") && ");
        std::string value = cat("native_double_value(", left, ") ", float_op, " native_double_value(", right, ")");
        if_likely(cat(check, "native_box_double(c, ", value, ", &result)"), finish);
      }
    });
  }
  flush_stack();
  emit_runtime_next("binary", next, opcode);
}

// The values that are tracked instead of being on the stack.

void NativeGenerator::track(const std::string& text) {
  tracked_.push_back({ -1, text, false });
}

void NativeGenerator::track_local(int index) {
  int size = static_cast<int>(tracked_.size());
  if (index < size) {
    tracked_.push_back(tracked_[size - 1 - index]);
  } else {
    tracked_.push_back({ index - size + pending_drops_, "", false });
  }
}

void NativeGenerator::pop_tracked(int count) {
  while (count > 0 && !tracked_.empty()) {
    tracked_.pop_back();
    count--;
  }
  pending_drops_ += count;
}

// Writes everything but the given number of values to the stack. Returns how
// many values are left, which is less if the rest are on the stack already.
// Most code can't use unboxed doubles, so it has to say that it can.
int NativeGenerator::keep_on_top(int count, bool allow_doubles) {
  int size = static_cast<int>(tracked_.size());
  int kept = std::min(count, size);
  if (!allow_doubles) {
    for (int i = size - kept; i < size; i++) {
      if (tracked_[i].is_double) kept = 0;
    }
  }
  int written = size - kept;
  if (pending_drops_ != 0) drop(pending_drops_);
  for (int i = 0; i < written; i++) {
    if (tracked_[i].is_double) {
      emit_box(tracked_[i].text);
    } else {
      push(tracked_[i].at(i - pending_drops_));
    }
  }
  tracked_.erase(tracked_.begin(), tracked_.begin() + written);
  for (auto& value : tracked_) {
    if (value.slot >= 0) value.slot += written - pending_drops_;
  }
  pending_drops_ = 0;
  return kept;
}

void NativeGenerator::flush_stack() {
  keep_on_top(0);
}

// The value at the given index after a call to keep_on_top.
std::string NativeGenerator::operand(int index, int kept) const {
  if (index < kept) return tracked_[tracked_.size() - 1 - index].at(0);
  return stack_at(index - kept);
}

// The double at the given index after a call to keep_on_top.
std::string NativeGenerator::double_operand(int index, int kept) const {
  if (index < kept && tracked_[tracked_.size() - 1 - index].is_double) {
    return tracked_[tracked_.size() - 1 - index].text;
  }
  return cat("native_double_value(", operand(index, kept), ")");
}

// Integers are done right here. Overflowing into a large integer needs the
// runtime, but it doesn't run any Toit code, so it's a plain call.
void NativeGenerator::emit_int_operation(uint8* bcp, Opcode opcode, const char* helper) {
  Operands info = operands(bcp);
  int kept = keep_on_top(2);
  auto slow_path = [&] {
    auto saved = tracked_;
    flush_stack();
    line(cat("NATIVE_RUNTIME_CALL(native_call_int_stub(sp, c, ", opcode, "));"));
    tracked_ = saved;
  };
  if (info.can_be_smis && (info.is_likely || is_hot_site(bcp))) {
    std::string left = operand(1, kept);
    std::string right = operand(0, kept);
    std::string check = smi_check(info, left, right);
    if (!check.empty()) check += " && ";
    scope([&] {
      line("Object* result = nullptr;");
      line(cat("if (NATIVE_LIKELY(", check, helper, "(", left, ", ", right, ", &result))) {"));
      if (kept == 2) {
        push("result");
      } else {
        drop_push(2 - kept, "result");
      }
      line("} else {");
      slow_path();
      line("}");
    });
  } else {
    slow_path();
  }
  pop_tracked(kept);
}

// Known floats stay unboxed for as long as nothing else needs to see them. If
// an operand is an object nobody else can see, we keep the result in that.
void NativeGenerator::emit_float_operation(uint8* bcp, const char* float_op) {
  int kept = keep_on_top(2, true);
  std::string value = cat(double_operand(1, kept), " ", float_op, " ", double_operand(0, kept));
  auto reused = current_info_->reused_floats.find(bcp);
  if (reused != current_info_->reused_floats.end() && reused->second >= kept) {
    bool reuses_left = reused->second == 1;
    line(cat("native_set_double_value(", operand(reused->second, kept), ", ", value, ");"));
    if (reuses_left) {
      if (kept == 0) drop(1);
      pop_tracked(kept);
    } else {
      stack_at_put(1, stack_at(0));
      drop(1);
    }
    return;
  }
  std::string name = cat("d", double_count_++);
  line(cat("double ", name, " = ", value, ";"));
  pop_tracked(2);
  tracked_.push_back({ -1, name, true });
}

// Boxing only needs the runtime when new space is full. Code that isn't marked
// as hot can still be called from loops, and the stub is much slower than this.
void NativeGenerator::emit_box(const std::string& value) {
  std::string slow_path = cat("NATIVE_RUNTIME_CALL(native_call_double_stub(sp, c, ", value, "));");
  scope([&] {
    line("Object* box = nullptr;");
    line(cat("if (NATIVE_LIKELY(native_box_double(c, ", value, ", &box))) {"));
    push("box");
    line("} else {");
    line(slow_path);
    line("}");
  });
}

void NativeGenerator::emit_relational(uint8* bcp, uint8* next, Opcode opcode, const char* op) {
  Operands operands = this->operands(bcp);
  bool is_merged = current_info_->merged_comparisons.count(bcp) != 0;
  int kept = (is_merged || operands.are_floats) ? keep_on_top(2, operands.are_floats) : 0;
  std::string left = operand(1, kept);
  std::string right = operand(0, kept);
  std::string smi_compare = cat("NATIVE_COMPARE_SMIS(", left, ", ", op, ", ", right, ")");
  if (operands.are_ints || operands.are_floats) {
    std::string compare = smi_compare;
    if (operands.are_floats) {
      compare = cat(double_operand(1, kept), " ", op, " ", double_operand(0, kept));
    } else if (!operands.are_smis()) {
      compare = cat("NATIVE_COMPARE_INTS(", smi_check(operands, left, right), ", ", left, ", ", op, ", ", right, ")");
    }
    if (is_merged) {
      // There is no need to create a boolean just to branch on it. The code
      // that is branched to can be right here, where it could shadow the name.
      Opcode next_opcode = static_cast<Opcode>(*next);
      std::string taken = cat("taken", nesting_);
      scope([&] {
        line(cat("bool ", taken, " = ", compare, ";"));
        pop_tracked(kept);
        if (kept != 2) drop(2 - kept);
        std::string condition = next_opcode == BRANCH_IF_TRUE ? taken : "!" + taken;
        emit_branch(next + Utils::read_unaligned_uint16(next + 1), condition, false, null);
      });
    } else if (operands.are_floats) {
      scope([&] {
        line(cat("bool result = ", compare, ";"));
        pop_tracked(2);
        flush_stack();
        push(boolean("result"));
      });
    } else {
      drop_push(2, boolean(compare));
    }
    return;
  }
  // Comparisons are too small for the check to matter for the size.
  if (operands.can_be_smis) {
    if_likely(smi_check(operands), [&] {
      line(cat("bool result = ", smi_compare, ";"));
      emit_fast_result(next, "result");
    });
  }
  emit_runtime_next("binary", next, opcode);
}

// Finishes the fast path of a comparison that can also take a slow path. The
// slow path produces a boolean and continues at the next bytecode, but
// if that is a branch, the fast path can go directly to where it goes.
void NativeGenerator::emit_fast_result(uint8* next, const std::string& result) {
  Opcode next_opcode = static_cast<Opcode>(*next);
  if (branches_after_comparison(next)) {
    uint8* target = next + Utils::read_unaligned_uint16(next + 1);
    uint8* fall_through = next + BRANCH_IF_TRUE_LENGTH;
    bool on_true = next_opcode == BRANCH_IF_TRUE;
    drop(2);
    if_(result, [&] {
      emit_goto(on_true ? target : fall_through);
    });
    tail_call(label(on_true ? fall_through : target));
    return;
  }
  drop_push(2, boolean(result));
  emit_goto(next);
}

void NativeGenerator::emit_bit_operation(uint8* bcp, uint8* next, Opcode opcode, const char* op, const char* helper) {
  if (operands(bcp).are_smis()) {
    // Smis have a zero tag, so we can work directly on the tagged values.
    drop_push(2, cat("NATIVE_OBJECT(NATIVE_WORD(STACK_AT(1)) ", op, " NATIVE_WORD(STACK_AT(0)))"));
    return;
  }
  emit_arithmetic(bcp, next, opcode, helper);
}

// The runtime has to look at the class of the receiver to find out what it is
// dealing with. The propagated types tell us which kinds of collections the
// receiver can be, so we only generate code for those. If there is just one
// possibility, it doesn't even need a check.
std::vector<NativeGenerator::Collection> NativeGenerator::collections_at(uint8* bcp, int stack_offset) const {
  std::vector<Collection> result;
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (static_cast<int>(input.size()) != stack_offset + 1 || input[0].is_block()) return result;
  bool is_certain = input[0].size(TypeSet::words_per_type(program_)) == 1;
  // It's worth the code in hot places, and everywhere the types are precise
  // enough for it to be small.
  if (!is_certain && !is_hot_site(bcp)) return result;
  std::string receiver = stack_at(stack_offset);
  auto add = [&](Smi* id, const char* name) {
    int class_id = Smi::value(id);
    if (!input[0].contains(class_id)) return;
    std::string guard = is_certain
        ? std::string()
        : "native_class_id(" + receiver + ", SMI_ID) == " + std::to_string(class_id) + " && ";
    result.push_back({ name, guard });
  };
  add(program_->list_class_id(), is_hot_site(bcp) ? "large_list" : "list");
  add(program_->array_class_id(), "array");
  add(program_->byte_array_class_id(), "byte_array");
  add(program_->string_class_id(), "string");
  return result;
}

void NativeGenerator::emit_at(uint8* bcp, uint8* next) {
  for (auto& collection : collections_at(bcp, 1)) {
    emit_result_if(cat(collection.guard, "native_", collection.name, "_at(c, STACK_AT(1), STACK_AT(0), &result)"), 2, next);
  }
  emit_runtime_next("at", next, 0);
}

void NativeGenerator::emit_at_put(uint8* bcp, uint8* next) {
  for (auto& collection : collections_at(bcp, 2)) {
    if (strcmp(collection.name, "string") == 0) continue;
    if (strcmp(collection.name, "byte_array") == 0) {
      emit_result_if(cat(collection.guard, "native_byte_array_at_put(STACK_AT(2), STACK_AT(1), STACK_AT(0), &result)"), 3, next);
      continue;
    }
    if_likely(cat(collection.guard, "native_", collection.name, "_at_put(c, STACK_AT(2), STACK_AT(1), STACK_AT(0), ",
        needs_write_barrier(bcp, 2) ? "true" : "false", ")"), [&] {
      drop_push(3, "STACK_AT(0)");
      emit_goto(next);
    });
  }
  emit_runtime_next("at_put", next, 0);
}

void NativeGenerator::emit_size(uint8* bcp, uint8* next, int selector) {
  for (auto& collection : collections_at(bcp, 0)) {
    if (strcmp(collection.name, "string") == 0) {
      emit_result_if(cat(collection.guard, "native_string_size(STACK_AT(0), &result)"), 1, next);
      continue;
    }
    // The size of a list is a field. It's the same for big lists.
    if (strcmp(collection.name, "list") != 0 && strcmp(collection.name, "large_list") != 0) continue;
    if_likely(cat(collection.guard, "native_is_smi(native_field(STACK_AT(0), 1))"), [&] {
      stack_at_put(0, "native_field(STACK_AT(0), 1)");
      emit_goto(next);
    });
  }
  emit_runtime_next("size", next, selector);
}

void NativeGenerator::emit_branch(uint8* target, const std::string& condition, bool is_back, uint8* entry) {
  auto branch = [&] {
    if (is_back) {
      if_unlikely("NativeRuntime::is_preempted(c)", [&] {
        emit_runtime("preempt", address_of(label(target)), pruned_entry(bci(entry) - Method::entry_offset()));
      });
    }
    emit_goto(target);
  };
  if (condition.empty()) {
    branch();
  } else {
    if_(condition, branch);
  }
}

// Returns the code for finding out if the value is true. Most of the time
// the types leave only one way to be false.
std::string NativeGenerator::truth_of(uint8* bcp, const std::string& value) const {
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (input.size() != 1 || input[0].is_block()) return cat("native_is_true(c, ", value, ")");
  bool can_be_false = input[0].contains(Smi::value(program_->false_class_id()));
  bool can_be_null = input[0].contains(Smi::value(program_->null_class_id()));
  if (can_be_false && can_be_null) return cat("native_is_true(c, ", value, ")");
  return cat(value, can_be_false ? " != c->false_object" : " != c->null_object");
}

// Returns the value on top of the stack for a branch that consumes it.
std::string NativeGenerator::pop_for_branch() {
  int kept = keep_on_top(1);
  std::string value = kept == 1 ? operand(0, 1) : "POP()";
  pop_tracked(kept);
  return value;
}

// Stores only need to tell the garbage collector about pointers to new objects.
bool NativeGenerator::needs_write_barrier(uint8* bcp, int index) const {
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (static_cast<int>(input.size()) <= index || input[index].is_block()) return true;
  TypeSet::Iterator it(input[index], TypeSet::words_per_type(program_));
  while (it.has_next()) {
    int id = it.next();
    bool is_immediate = id == Smi::value(program_->smi_class_id()) ||
        id == Smi::value(program_->null_class_id()) ||
        id == Smi::value(program_->true_class_id()) ||
        id == Smi::value(program_->false_class_id());
    if (!is_immediate) return true;
  }
  return false;
}

void NativeGenerator::emit_load_field(int field) {
  if (keep_on_top(1) == 1) {
    std::string object = operand(0, 1);
    pop_tracked(1);
    push(field_of(object, field));
  } else {
    stack_at_put(0, field_of(stack_at(0), field));
  }
}

// The bodies of 'repeat' and 'do' are blocks. The code here runs each time the
// block returns, which leaves its result on top of the stack. Below that is
// the current index, the frame and the arguments.
void NativeGenerator::emit_loop_intrinsic(uint8* bcp, bool is_array) {
  int arguments = 1 + Interpreter::FRAME_SIZE;
  drop(1);
  scope([&] {
    line("Object* current = STACK_AT(0);");
    line(cat("Object* block = ", stack_at(arguments), ";"));
    if_(cat("NATIVE_WORD(current) >= NATIVE_WORD(", stack_at(arguments + 1), ")"), [&] {
      drop(1);
      line("POP();  // The frame marker.");
      line("NativeFn next = NATIVE_FN(POP());");
      drop(is_array ? 2 : 1);
      stack_at_put(0, "c->null_object");
      tail_call("next");
    });
    stack_at_put(0, "NATIVE_OBJECT(NATIVE_WORD(current) + NATIVE_WORD(native_smi(1)))");
    if (is_array) {
      line(cat("Object* element = *native_array_slot(", stack_at(arguments + 2), ", static_cast<uintptr_t>(native_smi_value(current)));"));
    }
    push("block");
    line("NATIVE_SPLIT_STORES();");
    push(is_array ? "element" : "current");
    line("NativeFn target = NATIVE_FN(*NativeRuntime::from_block(c, block));");
    tail_call("target", address_of(label(bcp)), 2, "t");
  });
}

void NativeGenerator::emit_store_field(const char* instance, int field, bool needs_barrier) {
  const char* store = needs_barrier ? "native_set_field(c, " : "native_set_field_no_barrier(";
  line(cat(store, instance, ", ", field, ", value);"));
}

void NativeGenerator::emit_typecheck(uint8* bcp, Opcode opcode, bool is_as, int encoded, int length) {
  bool is_nullable = (encoded & 1) != 0;
  int index = encoded >> 1;
  bool is_interface = opcode == IS_INTERFACE || opcode == IS_INTERFACE_WIDE ||
      opcode == AS_INTERFACE || opcode == AS_INTERFACE_WIDE;
  auto check = [&](const char* target) {
    if (is_interface) {
      int offset = program_->interface_check_offsets[index];
      line(cat(target, "NativeRuntime::is_interface(c, value, ", offset, ");"));
    } else {
      int start = program_->class_check_ids[2 * index];
      int end = program_->class_check_ids[2 * index + 1];
      line("unsigned id = native_class_id(value, SMI_ID);");
      line(cat(target, start, " <= id && id < ", end, ";"));
    }
  };
  scope([&] {
    line("Object* value = STACK_AT(0);");
    if (is_nullable) {
      line("bool result = value == c->null_object;");
      if_("!result", [&] { check("result = "); });
    } else {
      check("bool result = ");
    }
    if (is_as) {
      if_unlikely("!result", [&] {
        emit_runtime_next("as_failure", bcp + length, bci(bcp + length));
      });
    } else {
      stack_at_put(0, boolean("result"));
    }
  });
}

void NativeGenerator::emit_tail_frame_move(int height, int outer_arity, int call_arity) {
  int parameter_start = height + Interpreter::FRAME_SIZE + outer_arity;
  spill();
  scope([&] {
    line(cat("Object* return_address = sp[", (height + 1), "];"));
    line(cat("memmove(sp + ", (parameter_start - call_arity), ", sp, ", call_arity, " * sizeof(Object*));"));
    line(cat("sp += ", (parameter_start - call_arity), ";"));
    line("*(--sp) = return_address;");
    line("*(--sp) = c->frame_marker;");
  });
  reload();
}

// Returns whether the code for the bytecode knows about values that haven't
// been written to the stack. All other bytecodes get to see the whole stack.
bool NativeGenerator::uses_tracked_stack(const MethodInfo& info, uint8* bcp) const {
  switch (static_cast<Opcode>(*bcp)) {
    case LOAD_LOCAL:
    case LOAD_LOCAL_WIDE:
    case LOAD_LOCAL_0:
    case LOAD_LOCAL_1:
    case LOAD_LOCAL_2:
    case LOAD_LOCAL_3:
    case LOAD_LOCAL_4:
    case LOAD_LOCAL_5:
    case LOAD_LITERAL:
    case LOAD_LITERAL_WIDE:
    case LOAD_NULL:
    case LOAD_SMI_0:
    case LOAD_SMIS_0:
    case LOAD_SMI_1:
    case LOAD_SMI_U8:
    case LOAD_SMI_U16:
    case LOAD_SMI_U32:
    case LOAD_FIELD:
    case LOAD_FIELD_WIDE:
    case POP:
    case POP_1:
    case BRANCH_IF_TRUE:
    case BRANCH_IF_FALSE:
    case BRANCH_IF_NOT_NULL:
    case INVOKE_ADD:
    case INVOKE_SUB:
    case INVOKE_MUL:
    case INVOKE_BIT_SHL:
    case INVOKE_BIT_SHR:
    case INVOKE_BIT_USHR:
    case INVOKE_DIV:
    case INVOKE_MOD:
      return true;
    case INVOKE_BIT_OR:
    case INVOKE_BIT_XOR:
    case INVOKE_BIT_AND:
      return !operands(bcp).are_smis();
    case INVOKE_EQ:
    case INVOKE_LT:
    case INVOKE_LTE:
    case INVOKE_GT:
    case INVOKE_GTE:
      return info.merged_comparisons.count(bcp) != 0 || operands(bcp).are_floats;
    default:
      return false;
  }
}

void NativeGenerator::emit_opcode(const MethodInfo& info, uint8* bcp) {
  Opcode opcode = static_cast<Opcode>(*bcp);
  int length = opcode_length[opcode];
  uint8* next = bcp + length;
  int byte1 = bcp[1];
  int wide1 = Utils::read_unaligned_uint16(bcp + 1);

  // Some of the bytecodes have a wide variant that only differs in the encoding.
  auto arg = [&](Opcode wide) { return (opcode == wide) ? wide1 : byte1; };

  if (!uses_tracked_stack(info, bcp)) flush_stack();

  switch (opcode) {
    case LOAD_LOCAL:
    case LOAD_LOCAL_WIDE:
      track_local(arg(LOAD_LOCAL_WIDE));
      break;
    case LOAD_LOCAL_0:
    case LOAD_LOCAL_1:
    case LOAD_LOCAL_2:
    case LOAD_LOCAL_3:
    case LOAD_LOCAL_4:
    case LOAD_LOCAL_5:
      track_local(opcode - LOAD_LOCAL_0);
      break;
    case POP_LOAD_LOCAL:
      stack_at_put(0, stack_at((byte1 + 1)));
      break;
    case STORE_LOCAL:
      stack_at_put(byte1, stack_at(0));
      break;
    case STORE_LOCAL_POP:
      stack_at_put(byte1, stack_at(0));
      drop(1);
      break;
    case LOAD_OUTER:
      line(cat("STACK_AT_PUT(0, NativeRuntime::from_block(c, STACK_AT(0))[", byte1, "]);"));
      break;
    case STORE_OUTER:
      scope([&] {
        line("Object* value = POP();");
        line(cat("NativeRuntime::from_block(c, STACK_AT(0))[", byte1, "] = value;"));
        stack_at_put(0, "value");
      });
      break;
    case LOAD_FIELD:
    case LOAD_FIELD_WIDE:
      emit_load_field(arg(LOAD_FIELD_WIDE));
      break;
    case LOAD_FIELD_LOCAL:
      push(field_of(stack_at(byte1 & 0x0f), byte1 >> 4));
      break;
    case POP_LOAD_FIELD_LOCAL:
      stack_at_put(0, field_of(stack_at((byte1 & 0x0f) + 1), byte1 >> 4));
      break;
    case STORE_FIELD:
    case STORE_FIELD_WIDE:
      scope([&] {
        line("Object* value = POP();");
        emit_store_field("STACK_AT(0)", arg(STORE_FIELD_WIDE), needs_write_barrier(bcp, 1));
        stack_at_put(0, "value");
      });
      break;
    case STORE_FIELD_POP:
      scope([&] {
        line("Object* value = POP();");
        emit_store_field("POP()", byte1, needs_write_barrier(bcp, 1));
      });
      break;
    case LOAD_LITERAL:
    case LOAD_LITERAL_WIDE:
      track(cat("c->literals[", arg(LOAD_LITERAL_WIDE), "]"));
      break;
    case LOAD_NULL:
      track("c->null_object");
      break;
    case LOAD_SMI_0:
      track(smi(0));
      break;
    case LOAD_SMIS_0:
      for (int i = 0; i < byte1; i++) track(smi(0));
      break;
    case LOAD_SMI_1:
      track(smi(1));
      break;
    case LOAD_SMI_U8:
      track(smi(byte1));
      break;
    case LOAD_SMI_U16:
      track(smi(wide1));
      break;
    case LOAD_SMI_U32:
      track(smi(Utils::read_unaligned_uint32(bcp + 1)));
      break;
    case LOAD_METHOD: {
      int id = Utils::read_unaligned_uint32(bcp + 1);
      Method target(program_->bytecodes, id);
      if (target.is_block_method()) {
        // The function pointer looks like a smi to the garbage collector.
        push(return_address(block_entry_label(id)));
      } else {
        push(smi(pruned_id(id)));
      }
      break;
    }
    case LOAD_GLOBAL_VAR:
    case LOAD_GLOBAL_VAR_WIDE:
      line(cat("PUSH(c->globals[", arg(LOAD_GLOBAL_VAR_WIDE), "]);"));
      break;
    case LOAD_GLOBAL_VAR_DYNAMIC:
      emit_runtime_next("load_global_dynamic", next, 0);
      break;
    case LOAD_GLOBAL_VAR_LAZY:
    case LOAD_GLOBAL_VAR_LAZY_WIDE: {
      int index = arg(LOAD_GLOBAL_VAR_LAZY_WIDE);
      scope([&] {
        line(cat("Object* value = c->globals[", index, "];"));
        if_("native_is_instance(value) && native_heap_class_id(value) == c->lazy_initializer_class_id", [&] {
          push(smi(index));
          push("value");
          emit_call(method_id(program_->run_global_initializer()), next);
        });
        push("value");
      });
      emit_goto(next);
      break;
    }
    case STORE_GLOBAL_VAR:
    case STORE_GLOBAL_VAR_WIDE:
      line(cat("c->globals[", arg(STORE_GLOBAL_VAR_WIDE), "] = STACK_AT(0);"));
      break;
    case STORE_GLOBAL_VAR_DYNAMIC:
      emit_runtime_next("store_global_dynamic", next, 0);
      break;
    case LOAD_BLOCK:
      line(cat("PUSH(NativeRuntime::to_block(c, sp + ", (byte1 - 1), "));"));
      break;
    case LOAD_OUTER_BLOCK:
      line(cat("STACK_AT_PUT(0, NativeRuntime::to_block(c, &NativeRuntime::from_block(c, STACK_AT(0))[", byte1, "]));"));
      break;
    case POP:
      pop_tracked(byte1);
      break;
    case POP_1:
      pop_tracked(1);
      break;
    case ALLOCATE:
    case ALLOCATE_WIDE:
      emit_runtime_next("allocate", next, arg(ALLOCATE_WIDE));
      break;
    case IS_CLASS:
    case IS_CLASS_WIDE:
      emit_typecheck(bcp, opcode, false, arg(IS_CLASS_WIDE), length);
      break;
    case IS_INTERFACE:
    case IS_INTERFACE_WIDE:
      emit_typecheck(bcp, opcode, false, arg(IS_INTERFACE_WIDE), length);
      break;
    case AS_CLASS:
    case AS_CLASS_WIDE:
      emit_typecheck(bcp, opcode, true, arg(AS_CLASS_WIDE), length);
      emit_goto(next);
      break;
    case AS_INTERFACE:
    case AS_INTERFACE_WIDE:
      emit_typecheck(bcp, opcode, true, arg(AS_INTERFACE_WIDE), length);
      emit_goto(next);
      break;
    case AS_LOCAL: {
      int local = byte1 >> 5;
      int index = byte1 & 0x1f;
      int start = program_->class_check_ids[2 * index];
      int end = program_->class_check_ids[2 * index + 1];
      scope([&] {
        line(cat("Object* value = STACK_AT(", local, ");"));
        line("unsigned id = native_class_id(value, SMI_ID);");
        if_unlikely(cat("id < ", start, " || id >= ", end), [&] {
          push("value");
          emit_runtime_next("as_failure", next, bci(next));
        });
      });
      emit_goto(next);
      break;
    }
    case INVOKE_STATIC:
      if (emit_inlined_leaf(info, bcp)) break;
      emit_call(program_->dispatch_table[wide1], next);
      break;
    case INVOKE_STATIC_TAIL: {
      int id = program_->dispatch_table[wide1];
      Method target(program_->bytecodes, id);
      emit_tail_frame_move(bcp[3], bcp[4], target.arity());
      tail_call(method_label(id));
      break;
    }
    case INVOKE_BLOCK:
      scope([&] {
        line(cat("Object** block = NativeRuntime::from_block(c, STACK_AT(", (byte1 - 1), "));"));
        line("NativeFn target = NATIVE_FN(*block);");
      tail_call("target", address_of(label(next)), byte1, "t");
      });
      break;
    case INVOKE_LAMBDA_TAIL:
      emit_runtime("lambda_tail", "nullptr", byte1);
      break;
    case INVOKE_INITIALIZER_TAIL:
      emit_runtime("initializer_tail", "nullptr", static_cast<word>(bcp[2]) << 16 | bcp[1]);
      break;
    case INVOKE_VIRTUAL:
    case INVOKE_VIRTUAL_WIDE:
      if (emit_inlined_leaf(info, bcp)) break;
      emit_virtual(bcp, next, arg(INVOKE_VIRTUAL_WIDE), Utils::read_unaligned_uint16(bcp + (opcode == INVOKE_VIRTUAL ? 2 : 3)));
      break;
    case INVOKE_VIRTUAL_GET:
      if (emit_inlined_accessor(bcp, next) || emit_inlined_leaf(info, bcp)) break;
      emit_virtual(bcp, next, 0, wide1);
      break;
    case INVOKE_VIRTUAL_SET:
      if (emit_inlined_accessor(bcp, next) || emit_inlined_leaf(info, bcp)) break;
      emit_virtual(bcp, next, 1, wide1);
      break;
    case INVOKE_ADD:
      emit_arithmetic(bcp, next, opcode, "native_add", "+");
      break;
    case INVOKE_SUB:
      emit_arithmetic(bcp, next, opcode, "native_sub", "-");
      break;
    case INVOKE_LT:
      emit_relational(bcp, next, opcode, "<");
      break;
    case INVOKE_LTE:
      emit_relational(bcp, next, opcode, "<=");
      break;
    case INVOKE_GT:
      emit_relational(bcp, next, opcode, ">");
      break;
    case INVOKE_GTE:
      emit_relational(bcp, next, opcode, ">=");
      break;
    case INVOKE_EQ:
      if (operands(bcp).are_ints || operands(bcp).are_floats) {
        emit_relational(bcp, next, opcode, "==");
      } else if (operands(bcp).is_likely || is_hot_site(bcp)) {
        scope([&] {
          line("int equals = native_equals(c, STACK_AT(1), STACK_AT(0));");
          if_likely("equals >= 0", [&] {
            emit_fast_result(next, "equals == 1");
          });
        });
        emit_runtime_next("binary", next, opcode);
      } else {
        emit_runtime_next("binary", next, opcode);
      }
      break;
    case INVOKE_BIT_OR:
      emit_bit_operation(bcp, next, opcode, "|", "native_bit_or");
      break;
    case INVOKE_BIT_XOR:
      emit_bit_operation(bcp, next, opcode, "^", "native_bit_xor");
      break;
    case INVOKE_BIT_AND:
      emit_bit_operation(bcp, next, opcode, "&", "native_bit_and");
      break;
    case INVOKE_MUL:
      emit_arithmetic(bcp, next, opcode, "native_mul", "*");
      break;
    case INVOKE_BIT_SHL:
      emit_arithmetic(bcp, next, opcode, "native_shl");
      break;
    case INVOKE_BIT_SHR:
      emit_arithmetic(bcp, next, opcode, "native_shr");
      break;
    case INVOKE_BIT_USHR:
      emit_arithmetic(bcp, next, opcode, "native_ushr");
      break;
    case INVOKE_DIV:
      emit_arithmetic(bcp, next, opcode, "native_div", "/");
      break;
    case INVOKE_MOD:
      emit_arithmetic(bcp, next, opcode, "native_mod");
      break;
    case INVOKE_AT:
      emit_at(bcp, next);
      break;
    case INVOKE_AT_PUT:
      emit_at_put(bcp, next);
      break;
    case INVOKE_SIZE:
      emit_size(bcp, next, wide1);
      break;
    case BRANCH:
      emit_goto(bcp + wide1);
      break;
    case BRANCH_IF_TRUE:
      emit_branch(bcp + wide1, truth_of(bcp, pop_for_branch()), false, null);
      break;
    case BRANCH_IF_FALSE:
      emit_branch(bcp + wide1, cat("!(", truth_of(bcp, pop_for_branch()), ")"), false, null);
      break;
    case BRANCH_IF_NOT_NULL:
      emit_branch(bcp + wide1, pop_for_branch() + " != c->null_object", false, null);
      break;
    case BRANCH_BACK:
    case BRANCH_BACK_IF_TRUE:
    case BRANCH_BACK_IF_FALSE:
    case BRANCH_BACK_IF_NOT_NULL: {
      uint8* entry = bcp - Utils::read_unaligned_uint16(bcp + 3);
      std::string truth = truth_of(bcp, "POP()");
      std::string condition;
      if (opcode == BRANCH_BACK_IF_TRUE) condition = truth;
      if (opcode == BRANCH_BACK_IF_FALSE) condition = cat("!(", truth, ")");
      if (opcode == BRANCH_BACK_IF_NOT_NULL) condition = "POP() != c->null_object";
      emit_branch(bcp - wide1, condition, true, entry);
      break;
    }
    case PRIMITIVE:
    {
      int index = Utils::read_unaligned_uint16(bcp + 2);
      word y = (static_cast<word>(index) << 16) | (byte1 << 8) | module_infos[byte1][index].arity;
      spill();
      tail_call("NativeRuntime::primitive", address_of(label(next)), y, "NATIVE_OBJECT(&" + primitive_name(byte1, index) + ")");
    }
      break;
    case THROW:
      emit_runtime("throw_exception", "nullptr", 0);
      break;
    case RETURN:
    case RETURN_NULL: {
      int offset = byte1;
      int arity = bcp[2];
      scope([&] {
        line(cat("Object* result = ", (opcode == RETURN ? "STACK_AT(0)" : "c->null_object"), ";"));
        line(cat("NativeFn next = NATIVE_FN(", stack_at(offset + 1), ");"));
        drop_push((offset + Interpreter::FRAME_SIZE + arity), "result");
        tail_call("next");
      });
      break;
    }
    case NON_LOCAL_RETURN:
      emit_runtime("non_local_return", "nullptr", static_cast<word>(byte1 & 0x0f) << 16 | (byte1 >> 4));
      break;
    case NON_LOCAL_RETURN_WIDE:
      emit_runtime("non_local_return", "nullptr",
          static_cast<word>(wide1) << 16 | Utils::read_unaligned_uint16(bcp + 3));
      break;
    case NON_LOCAL_BRANCH:
      emit_runtime("non_local_branch",
          "reinterpret_cast<void*>(" + std::to_string(pruned_branch_target(Utils::read_unaligned_uint32(bcp + 2))) + ")",
          byte1);
      break;
    case IDENTICAL:
      drop_push(2, "NativeRuntime::identical(c, STACK_AT(1), STACK_AT(0))");
      break;
    case LINK:
      spill();
      line("sp -= 4;");
      line("NativeRuntime::link(c, sp);");
      reload();
      break;
    case UNLINK:
      line("NativeRuntime::unlink(c, POP());");
      break;
    case UNWIND:
      emit_runtime_next("unwind", next, 0);
      break;
    case HALT:
      emit_runtime_next("halt", next, byte1);
      break;
    case INTRINSIC_SMI_REPEAT:
      emit_loop_intrinsic(bcp, false);
      break;
    case INTRINSIC_ARRAY_DO:
      emit_loop_intrinsic(bcp, true);
      break;
    case INTRINSIC_HASH_DO:
      emit_runtime_next("hash_do", bcp, 0);
      break;
    case INTRINSIC_HASH_FIND:
      // This is an optimization. If it fails, the code that follows does the work.
      drop(7);
      break;
    case ILLEGAL_END:
      UNREACHABLE();
  }
}

std::string generate_native_code(Program* program, TypeDatabase* types, std::vector<int> methods) {
  NativeGenerator generator(program, types, methods);
  return generator.generate();
}

} // namespace toit::compiler
} // namespace toit
