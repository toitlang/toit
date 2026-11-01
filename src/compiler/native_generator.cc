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

#include "propagation/type_database.h"

#include "../bytecodes.h"
#include "../interpreter.h"
#include "../native.h"
#include "native_abi_source.h"
#include "../objects_inline.h"
#include "../program.h"

#include <algorithm>
#include <cstdlib>
#include <map>
#include <utility>
#include <vector>
#include <set>
#include <sstream>
#include <tuple>

namespace toit {
namespace compiler {

#define BYTECODE_LENGTH(name, length, format, print) length,
static const int opcode_length[] { BYTECODES(BYTECODE_LENGTH) -1 };
#undef BYTECODE_LENGTH

class NativeGenerator {
 public:
  NativeGenerator(Program* program, TypeDatabase* types, std::vector<int> methods);

  std::string generate();

 private:
  struct MethodInfo {
    Method method;
    uint8* end;
    std::set<uint8*> leaders;
    // Code in loops is hot. The whole method is hot if it is small or recursive.
    bool is_hot;
    std::vector<std::pair<uint8*, uint8*>> loops;
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
  std::stringstream out_;
  uint8* current_end_ = null;
  bool skip_next_opcode_ = false;

  int bci(uint8* bcp) const { return program_->absolute_bci_from_bcp(bcp); }
  int method_id(Method method) const { return bci(method.header_bcp()); }

  // The labels of the generated functions. The method functions check the stack
  // and fall into the code of the method.
  std::string method_label(int id) const {
    if (method_ids_.count(id) == 0) return "NativeRuntime::illegal";
    return "m" + std::to_string(id);
  }
  std::string method_label(Method method) const { return method_label(method_id(method)); }
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
    bool are_smis() const { return left_is_smi && right_is_smi; }
  };
  Operands operands(uint8* bcp) const;
  // The condition for the operands being smis; empty if they always are.
  std::string smi_check(const Operands& operands) const;
  bool is_smi_type(TypeSet type) const;
  bool is_int_type(TypeSet type) const;

  // Returns the method a virtual call goes to if there is only one
  // possible receiver class. Returns -1 otherwise.
  int single_target(uint8* bcp, int arity, int selector_offset) const;

  bool ends_block(uint8* bcp) const;
  bool stays_in_block(uint8* bcp) const;
  // The code that follows calls that don't return isn't needed.
  bool is_dead_continuation(uint8* bcp, uint8* next) const;

  void find_leaders(MethodInfo* info);
  void find_hot_code(MethodInfo* info);
  bool is_hot_code(const MethodInfo& info, uint8* bcp) const;
  const char* attributes(const MethodInfo& info, uint8* bcp) const;
  void emit_declarations();
  void emit_tables();
  void emit_method(const MethodInfo& info);
  void emit_block_entry(Method method, bool is_dead);
  void emit_block(const MethodInfo& info, uint8* begin, uint8* end);
  void emit_opcode(const MethodInfo& info, uint8* bcp);

  void emit_goto(uint8* target);
  void emit_call(int id, uint8* next);
  void emit_runtime(const char* helper, const std::string& x, word y);
  void emit_runtime_next(const char* helper, uint8* next, word y);
  typedef std::tuple<int, int, bool> VirtualThunk;
  std::set<VirtualThunk> virtual_thunks_;
  std::string thunk_label(const VirtualThunk& thunk) const {
    return "v" + std::to_string(std::get<0>(thunk)) + "_" + std::to_string(std::get<1>(thunk)) +
        (std::get<2>(thunk) ? "_s" : "");
  }
  bool is_hot_site(uint8* bcp) const { return is_hot_code(*current_info_, bcp); }
  const MethodInfo* current_info_ = null;
  void emit_virtual(uint8* bcp, uint8* next, int stack_offset, int selector_offset);
  void emit_arithmetic(uint8* bcp, uint8* next, Opcode opcode, const char* helper);
  void emit_relational(const MethodInfo& info, uint8* bcp, uint8* next, Opcode opcode, const char* op);
  void emit_bit_operation(uint8* bcp, uint8* next, Opcode opcode, const char* op);
  void emit_fast_result(uint8* next, const std::string& result);
  void emit_branch(uint8* target, const char* condition, bool is_back, uint8* entry);
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
    methods_.push_back({ Method(program->bytecodes, methods[i]), end, {}, false, {} });
    method_ids_.insert(methods[i]);
  }
  for (auto& info : methods_) {
    find_leaders(&info);
    find_hot_code(&info);
  }
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
  // Integers take up two of the classes. That leaves room for null or a float.
  static const int LIKELY_TYPES = 3;
  int words = TypeSet::words_per_type(program_);
  result.is_likely = input[0].size(words) <= LIKELY_TYPES && input[1].size(words) <= LIKELY_TYPES;
  return result;
}

std::string NativeGenerator::smi_check(const Operands& operands) const {
  if (operands.are_smis()) return "";
  if (operands.left_is_smi) return "native_is_smi(STACK_AT(0))";
  if (operands.right_is_smi) return "native_is_smi(STACK_AT(1))";
  return "native_are_smis(STACK_AT(1), STACK_AT(0))";
}

int NativeGenerator::single_target(uint8* bcp, int arity, int selector_offset) const {
  std::vector<TypeSet> input = types_->input(bci(bcp));
  if (static_cast<int>(input.size()) != arity || input[0].is_block()) return -1;
  int words = TypeSet::words_per_type(program_);
  if (input[0].size(words) != 1) return -1;
  TypeSet::Iterator it(input[0], words);
  int index = it.next() + selector_offset;
  if (index >= program_->dispatch_table.length()) return -1;
  int entry = program_->dispatch_table[index];
  if (entry < 0 || method_ids_.count(entry) == 0) return -1;
  if (Method(program_->bytecodes, entry).selector_offset() != selector_offset) return -1;
  return entry;
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
      return operands(bcp).are_ints;
    case INVOKE_BIT_OR:
    case INVOKE_BIT_XOR:
    case INVOKE_BIT_AND:
      return operands(bcp).are_smis();
    default:
      return false;
  }
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

void NativeGenerator::find_leaders(MethodInfo* info) {
  current_end_ = info->end;
  uint8* bcp = info->method.entry();
  info->leaders.insert(bcp);
  if (program_->has_entry_task() && bcp == program_->entry_task().entry()) {
    // Tasks start after the first bytecode.
    info->leaders.insert(bcp + LOAD_NULL_LENGTH);
  }
  while (bcp < info->end) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    if (opcode >= ILLEGAL_END) break;
    int length = opcode_length[opcode];
    uint8* next = bcp + length;
    if (ends_block(bcp)) {
      if (is_dead_continuation(bcp, next)) {
        dead_continuations_.insert(next);
      } else {
        info->leaders.insert(next);
      }
      if (is_call(opcode)) return_points_.insert(next);
    }
    if (opcode == INTRINSIC_SMI_REPEAT || opcode == INTRINSIC_ARRAY_DO) {
      // The blocks return to the intrinsic.
      info->leaders.insert(bcp);
      return_points_.insert(bcp);
      if (next < info->end) info->leaders.insert(next);
    }
    switch (opcode) {
      case BRANCH:
      case BRANCH_IF_TRUE:
      case BRANCH_IF_FALSE:
      case BRANCH_IF_NOT_NULL:
        info->leaders.insert(bcp + Utils::read_unaligned_uint16(bcp + 1));
        if (next < info->end) info->leaders.insert(next);
        break;
      case BRANCH_BACK:
      case BRANCH_BACK_IF_TRUE:
      case BRANCH_BACK_IF_FALSE:
      case BRANCH_BACK_IF_NOT_NULL:
        info->leaders.insert(bcp - Utils::read_unaligned_uint16(bcp + 1));
        if (next < info->end) info->leaders.insert(next);
        break;
      default:
        break;
    }
    bcp = next;
  }
  for (uint8* leader : info->leaders) dead_continuations_.erase(leader);
}

void NativeGenerator::find_hot_code(MethodInfo* info) {
  info->is_hot = false;
  uint8* bcp = info->method.entry();
  while (bcp < info->end) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    if (opcode >= ILLEGAL_END) break;
    switch (opcode) {
      case BRANCH_BACK:
      case BRANCH_BACK_IF_TRUE:
      case BRANCH_BACK_IF_FALSE:
      case BRANCH_BACK_IF_NOT_NULL:
        info->loops.push_back({ bcp - Utils::read_unaligned_uint16(bcp + 1), bcp });
        break;
      case INVOKE_STATIC:
        if (program_->dispatch_table[Utils::read_unaligned_uint16(bcp + 1)] == method_id(info->method)) {
          info->is_hot = true;
        }
        break;
      default:
        break;
    }
    bcp += opcode_length[opcode];
  }
}

bool NativeGenerator::is_hot_code(const MethodInfo& info, uint8* bcp) const {
  if (info.is_hot) return true;
  for (auto& loop : info.loops) {
    if (bcp >= loop.first && bcp <= loop.second) return true;
  }
  return false;
}

const char* NativeGenerator::attributes(const MethodInfo& info, uint8* bcp) const {
  return is_hot_code(info, bcp) ? "" : "NATIVE_COLD ";
}

// The tables are written in assembler, which needs to know the symbols.
static std::string native_declaration(const std::string& name) {
  return "(NATIVE_PARAMS) __asm__(\"" + name + "\");\n";
}

void NativeGenerator::emit_declarations() {
  // Non-local branches go to bytecodes in other methods.
  for (auto& info : methods_) {
    uint8* bcp = info.method.entry();
    while (bcp < info.end) {
      Opcode opcode = static_cast<Opcode>(*bcp);
      if (opcode >= ILLEGAL_END) break;
      if (opcode == NON_LOCAL_BRANCH) branch_targets_.insert(Utils::read_unaligned_uint32(bcp + 2));
      if (opcode == LOAD_METHOD) {
        int id = Utils::read_unaligned_uint32(bcp + 1);
        Method target(program_->bytecodes, id);
        if (target.is_block_method() && method_ids_.count(id) == 0) dead_blocks_.insert(id);
      }
      bcp += opcode_length[opcode];
    }
  }
  for (auto& info : methods_) {
    for (int target : branch_targets_) {
      uint8* bcp = program_->bcp_from_absolute_bci(target);
      if (bcp >= info.method.entry() && bcp < info.end) info.leaders.insert(bcp);
    }
    int id = method_id(info.method);
    out_ << "static " << attributes(info, info.method.entry()) << "void " << method_label(id) << native_declaration(method_label(id));
    if (info.method.is_block_method()) out_ << "static void " << block_entry_label(id) << native_declaration(block_entry_label(id));
    current_end_ = info.end;
    for (uint8* leader : info.leaders) {
      if (leader < info.end) out_ << "static " << attributes(info, leader) << "void " << label(leader) << native_declaration(label(leader));
    }
  }
  for (int id : dead_blocks_) out_ << "static void " << block_entry_label(id) << native_declaration(block_entry_label(id));
  for (uint8* bcp : dead_continuations_) out_ << "static void " << label(bcp) << native_declaration(label(bcp));
  out_ << "\n";
}

void NativeGenerator::emit_tables() {
  // The selector check is done in the generated code, so we need both tables.
  List<int32> dispatch_table = program_->dispatch_table;
  out_ << "static const NativeFn vtable[] = {\n";
  for (int i = 0; i < dispatch_table.length(); i++) {
    int entry = dispatch_table[i];
    bool valid = entry >= 0 && method_ids_.count(entry) != 0;
    out_ << "  " << (valid ? method_label(entry) : std::string("NativeRuntime::illegal")) << ",\n";
  }
  out_ << "};\n\n";
  out_ << "static const int selectors[] = {\n";
  for (int i = 0; i < dispatch_table.length(); i++) {
    int entry = dispatch_table[i];
    bool valid = entry >= 0 && method_ids_.count(entry) != 0;
    int selector = valid ? Method(program_->bytecodes, entry).selector_offset() : -1;
    out_ << "  " << selector << ",\n";
  }
  out_ << "};\n\n";

  std::map<int, std::string> entries;
  current_end_ = null;
  for (auto& info : methods_) entries[bci(info.method.entry())] = method_label(info.method);
  if (program_->has_entry_task() && method_ids_.count(method_id(program_->entry_task())) != 0) {
    uint8* task = program_->entry_task().entry() + LOAD_NULL_LENGTH;
    entries[bci(task)] = label(task);
  }
  for (int target : branch_targets_) entries[target] = label(program_->bcp_from_absolute_bci(target));

  std::set<std::string> used;
  for (auto& it : entries) used.insert(it.second);
  for (uint8* bcp : return_points_) used.insert(label(bcp));
  for (auto& name : used) out_ << "NATIVE_USED(" << name << ");\n";

  // These are the tables described in native_abi.h.
  out_ << "__asm__(NATIVE_TABLE_SECTION R\"__toit__(\n";
  out_ << ".p2align 2\n";
  out_ << ".globl toit_native_entries\ntoit_native_entries:\n";
  for (auto& it : entries) out_ << ".long " << it.first << ", " << it.second << " - .\n";
  out_ << ".globl toit_native_returns\ntoit_native_returns:\n";
  for (uint8* bcp : return_points_) out_ << ".long " << label(bcp) << " - .\n";
  out_ << ".globl toit_native_return_deltas\ntoit_native_return_deltas:\n";
  int last_bci = 0;
  for (uint8* bcp : return_points_) {
    int delta = bci(bcp) - last_bci;
    last_bci = bci(bcp);
    out_ << ".byte ";
    for (; delta >= 0x80; delta >>= 7) out_ << ((delta & 0x7f) | 0x80) << ", ";
    out_ << delta << "\n";
  }
  out_ << ".text\n)__toit__\");\n\n";
  out_ << "extern const NativeEntry entries[] __asm__(\"toit_native_entries\");\n";
  out_ << "extern const int32_t returns[] __asm__(\"toit_native_returns\");\n";
  out_ << "extern const uint8_t return_deltas[] __asm__(\"toit_native_return_deltas\");\n\n";

  out_ << "static const NativeProgram native_program = {\n";
  out_ << "  NATIVE_ABI,\n";
  out_ << "  " << native_fingerprint(program_->bytecodes.data(), program_->bytecodes.length()) << "u,\n";
  out_ << "  " << program_->bytecodes.length() << ",\n";
  out_ << "  entries,\n";
  out_ << "  " << entries.size() << ",\n";
  out_ << "  returns,\n";
  out_ << "  return_deltas,\n";
  out_ << "  " << return_points_.size() << ",\n";
  out_ << "};\n\n";
  out_ << "static int registered = NativeRuntime::register_program(&native_program);\n";
}

std::string NativeGenerator::generate() {
  out_ << "// Generated by the Toit compiler.\n";
  out_ << "#define NATIVE_ABI " << NATIVE_ABI << "u\n";
  out_ << NATIVE_ABI_SOURCE << "\n";
  out_ << "using namespace toit;\n\n";
  out_ << "static const unsigned SMI_ID = " << Smi::value(program_->smi_class_id()) << ";\n\n";
  emit_declarations();
  emit_tables();
  out_ << "\n";
  // The thunks are found while emitting the methods, but must be declared first.
  std::string declarations = out_.str();
  out_.str("");
  for (auto& info : methods_) emit_method(info);
  std::string body = out_.str();
  out_.str("");
  out_ << declarations;
  for (auto& thunk : virtual_thunks_) out_ << "static void " << thunk_label(thunk) << "(NATIVE_PARAMS);\n";
  out_ << body;
  for (int id : dead_blocks_) emit_block_entry(Method(program_->bytecodes, id), true);
  for (uint8* bcp : dead_continuations_) {
    out_ << "static void " << label(bcp) << "(NATIVE_PARAMS) {\n";
    out_ << "  NATIVE_TAIL NativeRuntime::illegal(NATIVE_ARGS);\n";
    out_ << "}\n";
  }
  for (auto& thunk : virtual_thunks_) {
    int selector_offset = std::get<0>(thunk);
    int stack_offset = std::get<1>(thunk);
    out_ << "static void " << thunk_label(thunk) << "(NATIVE_PARAMS) {\n";
    if (std::get<2>(thunk)) {
      out_ << "  unsigned index = native_class_id(STACK_AT(" << stack_offset << "), SMI_ID) + " << selector_offset << ";\n";
    } else {
      out_ << "  unsigned index = native_heap_class_id(STACK_AT(" << stack_offset << ")) + " << selector_offset << ";\n";
    }
    out_ << "  if (NATIVE_LIKELY(selectors[index] == " << selector_offset << ")) {\n";
    out_ << "    PUSH(reinterpret_cast<Object*>(x));\n";
    out_ << "    PUSH(c->frame_marker);\n";
    out_ << "    NATIVE_TAIL vtable[index](NATIVE_ARGS);\n";
    out_ << "  }\n";
    out_ << "  NATIVE_TAIL NativeRuntime::virtual_fallback(sp, c, x, " << (static_cast<word>(selector_offset) << 8 | stack_offset) << ");\n";
    out_ << "}\n";
  }
  return out_.str();
}

// Blocks can be called with too many arguments. The caller leaves the
// number of arguments in y and the return address in x. A block that is
// dead can still be called, because it is the block that checks the
// arguments, so it gets the check without the code of the block.
void NativeGenerator::emit_block_entry(Method method, bool is_dead) {
  int id = method_id(method);
  out_ << "static void " << block_entry_label(id) << "(NATIVE_PARAMS) {\n";
  out_ << "  intptr_t extra = y - " << method.arity() << ";\n";
  out_ << "  if (NATIVE_UNLIKELY(extra < 0)) NATIVE_TAIL NativeRuntime::block_failure(sp, c, x, (" << id << " << 8) | y);\n";
  if (is_dead) {
    out_ << "  NATIVE_TAIL NativeRuntime::illegal(NATIVE_ARGS);\n";
  } else {
    out_ << "  DROP(extra);\n";
    out_ << "  PUSH(reinterpret_cast<Object*>(x));\n";
    out_ << "  PUSH(c->frame_marker);\n";
    out_ << "  NATIVE_TAIL " << method_label(id) << "(NATIVE_ARGS);\n";
  }
  out_ << "}\n";
}

void NativeGenerator::emit_method(const MethodInfo& info) {
  Method method = info.method;
  int id = method_id(method);
  current_end_ = info.end;
  current_info_ = &info;
  if (method.is_block_method()) emit_block_entry(method, false);
  out_ << "static void " << method_label(id) << "(NATIVE_PARAMS) {\n";
  out_ << "  if (NATIVE_UNLIKELY(NativeRuntime::needs_stack_check(c, sp, " << method.max_height() << "))) {\n";
  out_ << "    NATIVE_TAIL NativeRuntime::stack_overflow(sp, c, x, " << id << ");\n";
  out_ << "  }\n";
  out_ << "  NATIVE_TAIL " << label(method.entry()) << "(NATIVE_ARGS);\n";
  out_ << "}\n";

  std::vector<uint8*> leaders;
  for (uint8* leader : info.leaders) {
    if (leader < info.end) leaders.push_back(leader);
  }
  for (unsigned i = 0; i < leaders.size(); i++) {
    emit_block(info, leaders[i], (i + 1 == leaders.size()) ? info.end : leaders[i + 1]);
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
      return true;
    default:
      return false;
  }
}

void NativeGenerator::emit_block(const MethodInfo& info, uint8* begin, uint8* end) {
  current_end_ = info.end;
  out_ << "static void " << label(begin) << "(NATIVE_PARAMS) {\n";
  uint8* bcp = begin;
  bool terminated = false;
  while (bcp < end) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    if (opcode >= ILLEGAL_END) break;
    emit_opcode(info, bcp);
    terminated = is_terminal(opcode) || ends_block(bcp);
    bcp += opcode_length[opcode];
    if (skip_next_opcode_) {
      skip_next_opcode_ = false;
      bcp += opcode_length[*bcp];
    }
    if (terminated) break;
  }
  if (!terminated) {
    if (end != info.end) {
      emit_goto(end);
    } else {
      out_ << "  NATIVE_TAIL NativeRuntime::illegal(NATIVE_ARGS);\n";
    }
  }
  out_ << "}\n";
}

void NativeGenerator::emit_goto(uint8* target) {
  out_ << "  NATIVE_TAIL " << label(target) << "(NATIVE_ARGS);\n";
}

void NativeGenerator::emit_call(int id, uint8* next) {
  out_ << "  PUSH(reinterpret_cast<Object*>(&" << label(next) << "));\n";
  out_ << "  PUSH(c->frame_marker);\n";
  out_ << "  NATIVE_TAIL " << method_label(id) << "(NATIVE_ARGS);\n";
}

void NativeGenerator::emit_runtime(const char* helper, const std::string& x, word y) {
  out_ << "  NATIVE_TAIL NativeRuntime::" << helper << "(sp, c, " << x << ", " << y << ");\n";
}

void NativeGenerator::emit_runtime_next(const char* helper, uint8* next, word y) {
  emit_runtime(helper, "reinterpret_cast<void*>(&" + label(next) + ")", y);
}

void NativeGenerator::emit_virtual(uint8* bcp, uint8* next, int stack_offset, int selector_offset) {
  int target = single_target(bcp, stack_offset + 1, selector_offset);
  if (target >= 0) {
    emit_call(target, next);
    return;
  }
  // Most receivers cannot be smis, so there is no reason to check for it.
  std::vector<TypeSet> input = types_->input(bci(bcp));
  bool can_be_smi = static_cast<int>(input.size()) != stack_offset + 1 ||
      input[0].is_block() ||
      input[0].contains(Smi::value(program_->smi_class_id()));
  if (!is_hot_site(bcp)) {
    // Sites that aren't hot share the code for the lookup.
    auto thunk = std::make_tuple(selector_offset, stack_offset, can_be_smi);
    virtual_thunks_.insert(thunk);
    out_ << "  NATIVE_TAIL " << thunk_label(thunk) << "(sp, c, reinterpret_cast<void*>(&" << label(next) << "), y);\n";
    return;
  }
  if (can_be_smi) {
    out_ << "  { unsigned index = native_class_id(STACK_AT(" << stack_offset << "), SMI_ID) + " << selector_offset << ";\n";
  } else {
    out_ << "  { unsigned index = native_heap_class_id(STACK_AT(" << stack_offset << ")) + " << selector_offset << ";\n";
  }
  out_ << "    if (NATIVE_LIKELY(selectors[index] == " << selector_offset << ")) {\n";
  out_ << "      PUSH(reinterpret_cast<Object*>(&" << label(next) << "));\n";
  out_ << "      PUSH(c->frame_marker);\n";
  out_ << "      NATIVE_TAIL vtable[index](NATIVE_ARGS);\n";
  out_ << "    }\n  }\n";
  emit_runtime_next("virtual_fallback", next, static_cast<word>(selector_offset) << 8 | stack_offset);
}

void NativeGenerator::emit_arithmetic(uint8* bcp, uint8* next, Opcode opcode, const char* helper) {
  Operands info = operands(bcp);
  std::string check = smi_check(info);
  if (!check.empty()) check += " && ";
  if (info.can_be_smis && (info.is_likely || is_hot_site(bcp))) {
    out_ << "  { Object* result;\n";
    out_ << "    if (NATIVE_LIKELY(" << check << helper << "(STACK_AT(1), STACK_AT(0), &result))) {\n";
    out_ << "      STACK_AT_PUT(1, result);\n";
    out_ << "      DROP(1);\n";
    out_ << "      NATIVE_TAIL " << label(next) << "(NATIVE_ARGS);\n";
    out_ << "    }\n  }\n";
  }
  emit_runtime_next("binary", next, opcode);
}

void NativeGenerator::emit_relational(const MethodInfo& info, uint8* bcp, uint8* next, Opcode opcode, const char* op) {
  std::string smi_compare = std::string("reinterpret_cast<intptr_t>(STACK_AT(1)) ") + op + " reinterpret_cast<intptr_t>(STACK_AT(0))";
  Operands operands = this->operands(bcp);
  if (operands.are_ints) {
    std::string compare = smi_compare;
    if (!operands.are_smis()) {
      compare = "NATIVE_LIKELY(" + smi_check(operands) + ") ? (" + smi_compare + ")"
          + " : (native_int_value(STACK_AT(1)) " + op + " native_int_value(STACK_AT(0)))";
    }
    Opcode next_opcode = static_cast<Opcode>(*next);
    bool can_merge = next < info.end && info.leaders.count(next) == 0 &&
        (next_opcode == BRANCH_IF_TRUE || next_opcode == BRANCH_IF_FALSE);
    if (can_merge) {
      // There is no need to create a boolean just to branch on it.
      out_ << "  { bool result = " << compare << ";\n";
      out_ << "    DROP(2);\n";
      emit_branch(next + Utils::read_unaligned_uint16(next + 1),
                  next_opcode == BRANCH_IF_TRUE ? "result" : "!result", false, null);
      out_ << "  }\n";
      skip_next_opcode_ = true;
    } else {
      out_ << "  STACK_AT_PUT(1, (" << compare << ") ? c->true_object : c->false_object);\n";
      out_ << "  DROP(1);\n";
    }
    return;
  }
  if (operands.can_be_smis && (operands.is_likely || is_hot_site(bcp))) {
    out_ << "  if (NATIVE_LIKELY(" << smi_check(operands) << ")) {\n";
    out_ << "    bool result = " << smi_compare << ";\n";
    emit_fast_result(next, "result");
    out_ << "  }\n";
  }
  emit_runtime_next("binary", next, opcode);
}

// Finishes the fast path of a comparison that can also take a slow path. The
// slow path produces a boolean and continues at the next bytecode, but
// if that is a branch, the fast path can go directly to where it goes.
void NativeGenerator::emit_fast_result(uint8* next, const std::string& result) {
  Opcode next_opcode = static_cast<Opcode>(*next);
  if (next < current_end_ && (next_opcode == BRANCH_IF_TRUE || next_opcode == BRANCH_IF_FALSE)) {
    uint8* target = next + Utils::read_unaligned_uint16(next + 1);
    uint8* fall_through = next + BRANCH_IF_TRUE_LENGTH;
    bool on_true = next_opcode == BRANCH_IF_TRUE;
    out_ << "    DROP(2);\n";
    out_ << "    if (" << result << ") NATIVE_TAIL " << label(on_true ? target : fall_through) << "(NATIVE_ARGS);\n";
    out_ << "    NATIVE_TAIL " << label(on_true ? fall_through : target) << "(NATIVE_ARGS);\n";
    return;
  }
  out_ << "    STACK_AT_PUT(1, (" << result << ") ? c->true_object : c->false_object);\n";
  out_ << "    DROP(1);\n";
  out_ << "    NATIVE_TAIL " << label(next) << "(NATIVE_ARGS);\n";
}

void NativeGenerator::emit_bit_operation(uint8* bcp, uint8* next, Opcode opcode, const char* op) {
  if (operands(bcp).are_smis()) {
    // Smis have a zero tag, so we can work directly on the tagged values.
    out_ << "  STACK_AT_PUT(1, reinterpret_cast<Object*>(reinterpret_cast<intptr_t>(STACK_AT(1)) " << op << " reinterpret_cast<intptr_t>(STACK_AT(0))));\n";
    out_ << "  DROP(1);\n";
    return;
  }
  emit_runtime_next("binary", next, opcode);
}

void NativeGenerator::emit_branch(uint8* target, const char* condition, bool is_back, uint8* entry) {
  out_ << "  if (" << condition << ") {\n";
  if (is_back) {
    out_ << "    if (NATIVE_UNLIKELY(NativeRuntime::is_preempted(c))) {\n  ";
    emit_runtime("preempt", "reinterpret_cast<void*>(&" + label(target) + ")", bci(entry));
    out_ << "    }\n";
  }
  out_ << "  ";
  emit_goto(target);
  out_ << "  }\n";
}

void NativeGenerator::emit_typecheck(uint8* bcp, Opcode opcode, bool is_as, int encoded, int length) {
  bool is_nullable = (encoded & 1) != 0;
  int index = encoded >> 1;
  bool is_interface = opcode == IS_INTERFACE || opcode == IS_INTERFACE_WIDE ||
      opcode == AS_INTERFACE || opcode == AS_INTERFACE_WIDE;
  out_ << "  { Object* value = STACK_AT(0);\n";
  out_ << "    bool result = " << (is_nullable ? "value == c->null_object" : "false") << ";\n";
  if (is_interface) {
    int offset = program_->interface_check_offsets[index];
    out_ << "    if (!result) result = NativeRuntime::is_interface(c, value, " << offset << ");\n";
  } else {
    int start = program_->class_check_ids[2 * index];
    int end = program_->class_check_ids[2 * index + 1];
    out_ << "    if (!result) {\n";
    out_ << "      int id = native_class_id(value, SMI_ID);\n";
    out_ << "      result = " << start << " <= id && id < " << end << ";\n";
    out_ << "    }\n";
  }
  if (is_as) {
    out_ << "    if (NATIVE_UNLIKELY(!result)) {\n  ";
    emit_runtime_next("as_failure", bcp + length, bci(bcp + length));
    out_ << "    }\n";
  } else {
    out_ << "    STACK_AT_PUT(0, result ? c->true_object : c->false_object);\n";
  }
  out_ << "  }\n";
}

void NativeGenerator::emit_tail_frame_move(int height, int outer_arity, int call_arity) {
  out_ << "  { void* return_address = reinterpret_cast<void*>(STACK_AT(" << (height + 1) << "));\n";
  int parameter_start = height + Interpreter::FRAME_SIZE + outer_arity;
  out_ << "    memmove(sp + " << (parameter_start - call_arity) << ", sp, " << call_arity << " * sizeof(Object*));\n";
  out_ << "    DROP(" << (parameter_start - call_arity) << ");\n";
  out_ << "    PUSH(reinterpret_cast<Object*>(return_address));\n";
  out_ << "    PUSH(c->frame_marker);\n";
  out_ << "  }\n";
}

void NativeGenerator::emit_opcode(const MethodInfo& info, uint8* bcp) {
  Opcode opcode = static_cast<Opcode>(*bcp);
  int length = opcode_length[opcode];
  uint8* next = bcp + length;
  int byte1 = bcp[1];
  int wide1 = Utils::read_unaligned_uint16(bcp + 1);

  // Some of the bytecodes have a wide variant that only differs in the encoding.
  auto arg = [&](Opcode wide) { return (opcode == wide) ? wide1 : byte1; };

  switch (opcode) {
    case LOAD_LOCAL:
    case LOAD_LOCAL_WIDE:
      out_ << "  PUSH(STACK_AT(" << arg(LOAD_LOCAL_WIDE) << "));\n";
      break;
    case LOAD_LOCAL_0:
    case LOAD_LOCAL_1:
    case LOAD_LOCAL_2:
    case LOAD_LOCAL_3:
    case LOAD_LOCAL_4:
    case LOAD_LOCAL_5:
      out_ << "  PUSH(STACK_AT(" << (opcode - LOAD_LOCAL_0) << "));\n";
      break;
    case POP_LOAD_LOCAL:
      out_ << "  STACK_AT_PUT(0, STACK_AT(" << (byte1 + 1) << "));\n";
      break;
    case STORE_LOCAL:
      out_ << "  STACK_AT_PUT(" << byte1 << ", STACK_AT(0));\n";
      break;
    case STORE_LOCAL_POP:
      out_ << "  STACK_AT_PUT(" << byte1 << ", STACK_AT(0));\n";
      out_ << "  DROP(1);\n";
      break;
    case LOAD_OUTER:
      out_ << "  STACK_AT_PUT(0, NativeRuntime::from_block(c, STACK_AT(0))[" << byte1 << "]);\n";
      break;
    case STORE_OUTER:
      out_ << "  { Object* value = POP();\n";
      out_ << "    NativeRuntime::from_block(c, STACK_AT(0))[" << byte1 << "] = value;\n";
      out_ << "    STACK_AT_PUT(0, value);\n";
      out_ << "  }\n";
      break;
    case LOAD_FIELD:
    case LOAD_FIELD_WIDE:
      out_ << "  STACK_AT_PUT(0, native_field(STACK_AT(0), " << arg(LOAD_FIELD_WIDE) << "));\n";
      break;
    case LOAD_FIELD_LOCAL:
      out_ << "  PUSH(native_field(STACK_AT(" << (byte1 & 0x0f) << "), " << (byte1 >> 4) << "));\n";
      break;
    case POP_LOAD_FIELD_LOCAL:
      out_ << "  STACK_AT_PUT(0, native_field(STACK_AT(" << ((byte1 & 0x0f) + 1) << "), " << (byte1 >> 4) << "));\n";
      break;
    case STORE_FIELD:
    case STORE_FIELD_WIDE:
      out_ << "  { Object* value = POP();\n";
      out_ << "    native_set_field(c, STACK_AT(0), " << arg(STORE_FIELD_WIDE) << ", value);\n";
      out_ << "    STACK_AT_PUT(0, value);\n";
      out_ << "  }\n";
      break;
    case STORE_FIELD_POP:
      out_ << "  { Object* value = POP();\n";
      out_ << "    native_set_field(c, POP(), " << byte1 << ", value);\n";
      out_ << "  }\n";
      break;
    case LOAD_LITERAL:
    case LOAD_LITERAL_WIDE:
      out_ << "  PUSH(c->literals[" << arg(LOAD_LITERAL_WIDE) << "]);\n";
      break;
    case LOAD_NULL:
      out_ << "  PUSH(c->null_object);\n";
      break;
    case LOAD_SMI_0:
      out_ << "  PUSH(native_smi(0));\n";
      break;
    case LOAD_SMIS_0:
      for (int i = 0; i < byte1; i++) out_ << "  PUSH(native_smi(0));\n";
      break;
    case LOAD_SMI_1:
      out_ << "  PUSH(native_smi(1));\n";
      break;
    case LOAD_SMI_U8:
      out_ << "  PUSH(native_smi(" << byte1 << "));\n";
      break;
    case LOAD_SMI_U16:
      out_ << "  PUSH(native_smi(" << wide1 << "));\n";
      break;
    case LOAD_SMI_U32:
      out_ << "  PUSH(native_smi(" << Utils::read_unaligned_uint32(bcp + 1) << "));\n";
      break;
    case LOAD_METHOD: {
      int id = Utils::read_unaligned_uint32(bcp + 1);
      Method target(program_->bytecodes, id);
      if (target.is_block_method()) {
        // The function pointer looks like a smi to the garbage collector.
        out_ << "  PUSH(reinterpret_cast<Object*>(&" << block_entry_label(id) << "));\n";
      } else {
        out_ << "  PUSH(native_smi(" << id << "));\n";
      }
      break;
    }
    case LOAD_GLOBAL_VAR:
    case LOAD_GLOBAL_VAR_WIDE:
      out_ << "  PUSH(c->globals[" << arg(LOAD_GLOBAL_VAR_WIDE) << "]);\n";
      break;
    case LOAD_GLOBAL_VAR_DYNAMIC:
      emit_runtime_next("load_global_dynamic", next, bci(bcp));
      break;
    case LOAD_GLOBAL_VAR_LAZY:
    case LOAD_GLOBAL_VAR_LAZY_WIDE: {
      int index = arg(LOAD_GLOBAL_VAR_LAZY_WIDE);
      out_ << "  { Object* value = c->globals[" << index << "];\n";
      out_ << "    if (native_is_instance(value) && native_heap_class_id(value) == c->lazy_initializer_class_id) {\n";
      out_ << "      PUSH(native_smi(" << index << "));\n";
      out_ << "      PUSH(value);\n  ";
      emit_call(method_id(program_->run_global_initializer()), next);
      out_ << "    }\n";
      out_ << "    PUSH(value);\n";
      out_ << "  }\n";
      emit_goto(next);
      break;
    }
    case STORE_GLOBAL_VAR:
    case STORE_GLOBAL_VAR_WIDE:
      out_ << "  c->globals[" << arg(STORE_GLOBAL_VAR_WIDE) << "] = STACK_AT(0);\n";
      break;
    case STORE_GLOBAL_VAR_DYNAMIC:
      emit_runtime_next("store_global_dynamic", next, bci(bcp));
      break;
    case LOAD_BLOCK:
      out_ << "  PUSH(NativeRuntime::to_block(c, sp + " << byte1 << "));\n";
      break;
    case LOAD_OUTER_BLOCK:
      out_ << "  STACK_AT_PUT(0, NativeRuntime::to_block(c, &NativeRuntime::from_block(c, STACK_AT(0))[" << byte1 << "]));\n";
      break;
    case POP:
      out_ << "  DROP(" << byte1 << ");\n";
      break;
    case POP_1:
      out_ << "  DROP(1);\n";
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
      out_ << "  { Object* value = STACK_AT(" << local << ");\n";
      out_ << "    int id = native_class_id(value, SMI_ID);\n";
      out_ << "    if (NATIVE_UNLIKELY(!(" << start << " <= id && id < " << end << "))) {\n";
      out_ << "      PUSH(value);\n  ";
      emit_runtime_next("as_failure", next, bci(next));
      out_ << "    }\n  }\n";
      emit_goto(next);
      break;
    }
    case INVOKE_STATIC:
      emit_call(program_->dispatch_table[wide1], next);
      break;
    case INVOKE_STATIC_TAIL: {
      int id = program_->dispatch_table[wide1];
      Method target(program_->bytecodes, id);
      emit_tail_frame_move(bcp[3], bcp[4], target.arity());
      out_ << "  NATIVE_TAIL " << method_label(id) << "(NATIVE_ARGS);\n";
      break;
    }
    case INVOKE_BLOCK:
      out_ << "  { Object** block = NativeRuntime::from_block(c, STACK_AT(" << (byte1 - 1) << "));\n";
      out_ << "    NATIVE_TAIL reinterpret_cast<NativeFn>(*block)(sp, c, reinterpret_cast<void*>(&" << label(next) << "), " << byte1 << ");\n";
      out_ << "  }\n";
      break;
    case INVOKE_LAMBDA_TAIL:
      emit_runtime("lambda_tail", "nullptr", byte1);
      break;
    case INVOKE_INITIALIZER_TAIL:
      emit_runtime("initializer_tail", "nullptr", static_cast<word>(bcp[2]) << 16 | bcp[1]);
      break;
    case INVOKE_VIRTUAL:
    case INVOKE_VIRTUAL_WIDE:
      emit_virtual(bcp, next, arg(INVOKE_VIRTUAL_WIDE), Utils::read_unaligned_uint16(bcp + (opcode == INVOKE_VIRTUAL ? 2 : 3)));
      break;
    case INVOKE_VIRTUAL_GET:
      emit_virtual(bcp, next, 0, wide1);
      break;
    case INVOKE_VIRTUAL_SET:
      emit_virtual(bcp, next, 1, wide1);
      break;
    case INVOKE_ADD:
      emit_arithmetic(bcp, next, opcode, "native_add");
      break;
    case INVOKE_SUB:
      emit_arithmetic(bcp, next, opcode, "native_sub");
      break;
    case INVOKE_LT:
      emit_relational(info, bcp, next, opcode, "<");
      break;
    case INVOKE_LTE:
      emit_relational(info, bcp, next, opcode, "<=");
      break;
    case INVOKE_GT:
      emit_relational(info, bcp, next, opcode, ">");
      break;
    case INVOKE_GTE:
      emit_relational(info, bcp, next, opcode, ">=");
      break;
    case INVOKE_EQ:
      if (operands(bcp).are_ints) {
        emit_relational(info, bcp, next, opcode, "==");
      } else if (operands(bcp).is_likely || is_hot_site(bcp)) {
        out_ << "  { int equals = native_equals(c, STACK_AT(1), STACK_AT(0));\n";
        out_ << "    if (NATIVE_LIKELY(equals >= 0)) {\n";
        emit_fast_result(next, "equals == 1");
        out_ << "    }\n  }\n";
        emit_runtime_next("binary", next, opcode);
      } else {
        emit_runtime_next("binary", next, opcode);
      }
      break;
    case INVOKE_BIT_OR:
      emit_bit_operation(bcp, next, opcode, "|");
      break;
    case INVOKE_BIT_XOR:
      emit_bit_operation(bcp, next, opcode, "^");
      break;
    case INVOKE_BIT_AND:
      emit_bit_operation(bcp, next, opcode, "&");
      break;
    case INVOKE_MUL:
      emit_arithmetic(bcp, next, opcode, "native_mul");
      break;
    case INVOKE_BIT_SHL:
    case INVOKE_BIT_SHR:
    case INVOKE_BIT_USHR:
    case INVOKE_DIV:
    case INVOKE_MOD:
      emit_runtime_next("binary", next, opcode);
      break;
    case INVOKE_AT:
      emit_runtime_next("at", next, 0);
      break;
    case INVOKE_AT_PUT:
      emit_runtime_next("at_put", next, 0);
      break;
    case INVOKE_SIZE:
      emit_runtime_next("size", next, wide1);
      break;
    case BRANCH:
      emit_goto(bcp + wide1);
      break;
    case BRANCH_IF_TRUE:
      emit_branch(bcp + wide1, "native_is_true(c, POP())", false, null);
      break;
    case BRANCH_IF_FALSE:
      emit_branch(bcp + wide1, "!native_is_true(c, POP())", false, null);
      break;
    case BRANCH_IF_NOT_NULL:
      emit_branch(bcp + wide1, "POP() != c->null_object", false, null);
      break;
    case BRANCH_BACK:
    case BRANCH_BACK_IF_TRUE:
    case BRANCH_BACK_IF_FALSE:
    case BRANCH_BACK_IF_NOT_NULL: {
      uint8* entry = bcp - Utils::read_unaligned_uint16(bcp + 3);
      const char* condition = "true";
      if (opcode == BRANCH_BACK_IF_TRUE) condition = "native_is_true(c, POP())";
      if (opcode == BRANCH_BACK_IF_FALSE) condition = "!native_is_true(c, POP())";
      if (opcode == BRANCH_BACK_IF_NOT_NULL) condition = "POP() != c->null_object";
      emit_branch(bcp - wide1, condition, true, entry);
      if (opcode == BRANCH_BACK) out_ << "  __builtin_unreachable();\n";
      break;
    }
    case PRIMITIVE:
      emit_runtime_next("primitive", next, static_cast<word>(byte1) << 16 | Utils::read_unaligned_uint16(bcp + 2));
      break;
    case THROW:
      emit_runtime("throw_exception", "nullptr", 0);
      break;
    case RETURN:
    case RETURN_NULL: {
      int offset = byte1;
      int arity = bcp[2];
      out_ << "  { Object* result = " << (opcode == RETURN ? "STACK_AT(0)" : "c->null_object") << ";\n";
      out_ << "    NativeFn next = reinterpret_cast<NativeFn>(STACK_AT(" << (offset + 1) << "));\n";
      out_ << "    DROP(" << (offset + Interpreter::FRAME_SIZE + arity) << ");\n";
      out_ << "    PUSH(result);\n";
      out_ << "    NATIVE_TAIL next(NATIVE_ARGS);\n";
      out_ << "  }\n";
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
          "reinterpret_cast<void*>(" + std::to_string(Utils::read_unaligned_uint32(bcp + 2)) + ")",
          byte1);
      break;
    case IDENTICAL:
      out_ << "  STACK_AT_PUT(1, NativeRuntime::identical(c, STACK_AT(1), STACK_AT(0)));\n";
      out_ << "  DROP(1);\n";
      break;
    case LINK:
      out_ << "  DROP(-4);\n";
      out_ << "  NativeRuntime::link(c, sp);\n";
      break;
    case UNLINK:
      out_ << "  NativeRuntime::unlink(c, POP());\n";
      break;
    case UNWIND:
      emit_runtime_next("unwind", next, 0);
      break;
    case HALT:
      emit_runtime_next("halt", next, byte1);
      break;
    case INTRINSIC_SMI_REPEAT:
      emit_runtime_next("smi_repeat", bcp, 0);
      break;
    case INTRINSIC_ARRAY_DO:
      emit_runtime_next("array_do", bcp, 0);
      break;
    case INTRINSIC_HASH_DO:
      // These are optimizations. If they fail, the code that follows does the work.
      out_ << "  DROP(1);\n";
      break;
    case INTRINSIC_HASH_FIND:
      out_ << "  DROP(7);\n";
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
