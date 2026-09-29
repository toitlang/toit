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

// Compiles the IR to a WebAssembly module that uses the WebAssembly GC.
//
// Representation of values. Every Toit value is an 'eqref':
// - Small integers are 'i31ref's. Integers that don't fit are boxed in a
//   '$LargeInt' struct with an i64.
// - null is the null reference.
// - All other objects are structs that are subtypes of '$Object', whose
//   first field is the class id. Instances have one struct type per class,
//   mirroring the class hierarchy, with one field per Toit field. Strings,
//   byte arrays, arrays, and floats have special struct types.
// - Blocks are '$Block' structs with a function reference and the
//   environment of the function that created them. Every function that
//   contains blocks allocates an environment struct for the locals that are
//   accessed from its blocks. Blocks follow the 'parent' links of
//   environments to reach locals of outer functions.
//
// Calls:
// - All methods take and return 'eqref's.
// - Static calls are direct calls. Tail calls use 'return_call'.
// - Virtual calls use the Toit dispatch table as the WebAssembly function
//   table: the target is at 'class-id + selector-offset'. As the table is
//   compressed, the selector offset of every slot is stored in an array and
//   checked before the call.
// - Blocks and lambdas have uniform signatures: they get the number of
//   passed arguments, and the arguments padded with nulls to the maximum
//   arity of the program. This implements Toit's rule that blocks and
//   lambdas can be called with more arguments than they declare.
//
// Control flow:
// - Toit exceptions are WebAssembly exceptions with the '$throw' tag.
// - Non-local returns from blocks throw '$nlr' with the environment of the
//   targeted function, which catches it and returns.
// - The finally handlers of try/finally catch all exceptions, run the
//   handler and rethrow.
//
// Primitives are implemented in the runtime (wasm_runtime.wat). They return
// a '$Failure' struct if they fail. Missing primitives always fail with
// "UNIMPLEMENTED".

#include <stdarg.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "wasm_backend.h"

#include "../entry_points.h"
#include "../interpreter.h"
#include "../objects.h"

extern "C" {
  extern unsigned char toit_wasm_runtime_wat[];
  extern unsigned int toit_wasm_runtime_wat_len;
}

namespace toit {
namespace compiler {

namespace {

// ---------------------------------------------------------------------------
// Helpers.

std::string format(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
std::string format(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char buffer[512];
  int length = vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);
  if (length < static_cast<int>(sizeof(buffer))) return std::string(buffer, length);
  std::string result(length, '\0');
  va_start(args, fmt);
  vsnprintf(&result[0], length + 1, fmt, args);
  va_end(args);
  return result;
}

// Returns a version of the name that is a valid WebAssembly text identifier.
std::string sanitize(const char* name) {
  std::string result;
  for (const char* p = name; *p != '\0'; p++) {
    char c = *p;
    bool is_id_char = ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') ||
        strchr("!#$%&'*+-./:<=>?@\\^_`|~", c) != null;
    result += is_id_char ? c : '_';
  }
  return result;
}

// Encodes the bytes for a WebAssembly text string literal.
std::string wat_string(const uint8* bytes, int length) {
  std::string result = "\"";
  for (int i = 0; i < length; i++) {
    uint8 c = bytes[i];
    if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') {
      result += static_cast<char>(c);
    } else {
      result += format("\\%02x", c);
    }
  }
  result += "\"";
  return result;
}

// The functions of the IR that get their own WebAssembly function: methods,
// global initializers, blocks, and lambdas.
struct FunctionInfo {
  // Whether this function contains blocks. Such functions allocate an
  // environment.
  bool has_env = false;
  // The locals and parameters that are accessed from nested blocks, and thus
  // live in the environment.
  std::vector<ir::Local*> env_slots;
  std::map<ir::Local*, int> env_slot_index;
  // Whether a block returns non-locally from this function.
  bool is_nlr_target = false;
  // The loops that are the targets of 'break' or 'continue' in blocks.
  std::set<ir::While*> nl_branch_loops;
  // The index of the environment struct type.
  int env_type = -1;

  void add_env_slot(ir::Local* local) {
    if (env_slot_index.find(local) != env_slot_index.end()) return;
    env_slot_index[local] = static_cast<int>(env_slots.size());
    env_slots.push_back(local);
  }
};

// Computes the FunctionInfo for all functions of a method (and its lambdas).
//
// Blocks refer to locals of enclosing functions through a 'block_depth'.
// This visitor keeps a stack of the lexically enclosing functions to find
// the function that owns the local. Lambdas capture by value, so they start
// a new stack.
class EnvAnalyzer : public ir::TraversingVisitor {
 public:
  explicit EnvAnalyzer(std::map<ir::Node*, FunctionInfo>* infos) : infos_(infos) {}

  void analyze(ir::Method* method) {
    stack_.push_back(method);
    info(method);
    if (method->body() != null) visit(method->body());
    stack_.pop_back();
  }

  void visit_Code(ir::Code* node) {
    info(node);
    if (node->is_block()) {
      info(stack_.back())->has_env = true;
      stack_.push_back(node);
      visit(node->body());
      stack_.pop_back();
    } else {
      // Lambdas are separate roots.
      auto saved_stack = stack_;
      auto saved_loops = loops_;
      stack_.clear();
      loops_.clear();
      stack_.push_back(node);
      visit(node->body());
      stack_ = saved_stack;
      loops_ = saved_loops;
    }
  }

  void visit_While(ir::While* node) {
    visit(node->condition());
    loops_.push_back(std::make_pair(static_cast<int>(stack_.size()) - 1, node));
    visit(node->body());
    loops_.pop_back();
    visit(node->update());
  }

  void visit_ReferenceLocal(ir::ReferenceLocal* node) {
    capture(node->target(), node->block_depth());
  }

  void visit_ReferenceBlock(ir::ReferenceBlock* node) {
    capture(node->target(), node->block_depth());
  }

  void visit_AssignmentLocal(ir::AssignmentLocal* node) {
    TraversingVisitor::visit_AssignmentLocal(node);
    capture(node->local(), node->block_depth());
  }

  void visit_Return(ir::Return* node) {
    TraversingVisitor::visit_Return(node);
    int depth = node->depth();
    int target = depth == -1 ? 0 : static_cast<int>(stack_.size()) - 1 - depth;
    if (target != static_cast<int>(stack_.size()) - 1) {
      info(stack_[target])->is_nlr_target = true;
    }
  }

  void visit_LoopBranch(ir::LoopBranch* node) {
    if (node->block_depth() == 0) return;
    int target = static_cast<int>(stack_.size()) - 1 - node->block_depth();
    // Find the innermost loop in the target function.
    for (int i = static_cast<int>(loops_.size()) - 1; i >= 0; i--) {
      if (loops_[i].first == target) {
        info(stack_[target])->nl_branch_loops.insert(loops_[i].second);
        return;
      }
    }
    FATAL("no loop for non-local branch");
  }

 private:
  std::map<ir::Node*, FunctionInfo>* infos_;
  std::vector<ir::Node*> stack_;
  std::vector<std::pair<int, ir::While*>> loops_;

  FunctionInfo* info(ir::Node* node) { return &(*infos_)[node]; }

  void capture(ir::Local* local, int block_depth) {
    if (block_depth == 0) return;
    int owner = static_cast<int>(stack_.size()) - 1 - block_depth;
    ASSERT(owner >= 0);
    info(stack_[owner])->add_env_slot(local);
  }
};

// Computes the maximal number of arguments of block and lambda calls.
class ArityCollector : public ir::TraversingVisitor {
 public:
  int max_block_arity = 0;
  int max_lambda_arity = 0;
  int max_call_arity = 0;

  void visit_Code(ir::Code* node) {
    TraversingVisitor::visit_Code(node);
    if (node->is_block()) {
      max_block_arity = std::max(max_block_arity, static_cast<int>(node->parameters().length()));
    } else {
      int user_arity = static_cast<int>(node->parameters().length()) - node->captured_count();
      max_lambda_arity = std::max(max_lambda_arity, user_arity);
    }
  }

  void visit_CallBlock(ir::CallBlock* node) {
    TraversingVisitor::visit_CallBlock(node);
    max_block_arity = std::max(max_block_arity, static_cast<int>(node->arguments().length()));
  }

  void visit_CallBuiltin(ir::CallBuiltin* node) {
    TraversingVisitor::visit_CallBuiltin(node);
    if (node->target()->kind() == ir::Builtin::INVOKE_LAMBDA) {
      int arity = node->arguments()[0]->as_LiteralInteger()->value();
      max_lambda_arity = std::max(max_lambda_arity, arity);
    }
  }

  void visit_CallVirtual(ir::CallVirtual* node) {
    TraversingVisitor::visit_CallVirtual(node);
    max_call_arity = std::max(max_call_arity, node->shape().arity());
  }
};

// ---------------------------------------------------------------------------
// Module-level state.

class FunctionGen;

class ModuleGen {
 public:
  ModuleGen(ir::Program* program, DispatchTable* dispatch_table)
      : program_(program), dispatch_table_(dispatch_table) {}

  std::string emit();

  ir::Program* program() const { return program_; }
  DispatchTable* dispatch_table() const { return dispatch_table_; }

  int max_block_arity() const { return max_block_arity_; }
  int max_lambda_arity() const { return max_lambda_arity_; }

  FunctionInfo* info(ir::Node* node) {
    auto probe = infos_.find(node);
    ASSERT(probe != infos_.end());
    return &probe->second;
  }

  // The name of the function for a method or global initializer.
  const std::string& function_name(ir::Method* method) {
    auto probe = method_names_.find(method);
    ASSERT(probe != method_names_.end());
    return probe->second;
  }

  // The struct type for instances of the class.
  std::string class_type(ir::Class* klass) {
    auto probe = class_types_.find(klass);
    if (probe == class_types_.end()) {
      FATAL("no struct type for class %s", klass->name().c_str());
    }
    return probe->second;
  }

  int class_id(ir::Class* klass) { return klass->id(); }

  // Whether the class is represented by one of the special runtime types.
  bool is_special(ir::Class* klass) { return special_classes_.count(klass) != 0; }

  // Ensures that there is a function type for the given arity.
  std::string function_type(int arity) {
    max_arity_ = std::max(max_arity_, arity);
    return format("$f%d", arity);
  }

  std::string env_type(int index) { return format("$E%d", index); }
  int register_env_type(int slot_count) {
    env_slot_counts_.push_back(slot_count);
    return static_cast<int>(env_slot_counts_.size()) - 1;
  }

  // Literals are shared: strings and byte arrays live in an array that is
  // filled at startup.
  int string_literal(const char* data, int length);
  int byte_array_literal(List<uint8> data);
  std::string float_literal(double value);
  std::string large_integer_literal(int64 value);

  // Blocks and lambdas are compiled when they are encountered. Returns the
  // name of the function.
  std::string add_function(const std::string& text) {
    functions_ += text;
    return "";
  }
  std::string new_block_name(const std::string& outer) {
    return format("$b%d.%s", block_counter_++, outer.c_str() + 1);
  }
  // Lambdas are called through a table. Returns the index in the table.
  int new_lambda(const std::string& name) {
    lambda_functions_.push_back(name);
    return static_cast<int>(lambda_functions_.size()) - 1;
  }
  void declare_function_reference(const std::string& name) {
    referenced_functions_.push_back(name);
  }

  bool has_primitive(const std::string& name) {
    return runtime_functions_.count(name) != 0;
  }

  ir::Field* lambda_method_field() const { return lambda_method_field_; }
  ir::Field* lambda_arguments_field() const { return lambda_arguments_field_; }
  ir::Class* lambda_class() const { return lambda_class_; }

  ir::Method* entry_point(int index) const { return program_->entry_points()[index]; }

  // The global for the static field Task_.current.
  ir::Global* current_task_global() const { return current_task_global_; }

  // The WebAssembly name of the runtime's class-id global for the class with
  // the given name.
  std::string selector_offset_for(ir::Method* method);

 private:
  ir::Program* program_;
  DispatchTable* dispatch_table_;

  std::map<ir::Node*, FunctionInfo> infos_;
  std::map<ir::Method*, std::string> method_names_;
  std::map<ir::Class*, std::string> class_types_;
  std::set<ir::Class*> special_classes_;
  std::set<std::string> runtime_functions_;

  int max_block_arity_ = 0;
  int max_lambda_arity_ = 0;
  int max_arity_ = 4;
  int block_counter_ = 0;

  std::vector<int> env_slot_counts_;
  std::vector<std::string> lambda_functions_;
  std::vector<std::string> referenced_functions_;

  std::string functions_;

  // Literals.
  std::string string_data_;
  std::vector<std::pair<int, int>> string_literals_;   // Offset and length.
  std::map<std::string, int> string_literal_ids_;
  std::vector<std::pair<int, int>> byte_array_literals_;
  std::vector<std::string> constant_globals_;
  std::map<uint64, std::string> float_literals_;
  std::map<int64, std::string> large_integer_literals_;

  ir::Class* lambda_class_ = null;
  ir::Global* current_task_global_ = null;
  ir::Field* lambda_method_field_ = null;
  ir::Field* lambda_arguments_field_ = null;

  void collect_runtime_functions();
  void assign_names();
  void emit_types(std::string* out);
  void emit_dispatch_table(std::string* out, std::string* data, std::string* start);
  void emit_globals(std::string* out, std::string* start);
  void emit_class_constants(std::string* out);
  void emit_runtime_helpers(std::string* out);
  void compile_method(ir::Method* method);
};

// ---------------------------------------------------------------------------
// Function generation.

// How a local is stored.
struct LocalLocation {
  // Either a WebAssembly local (or parameter)...
  std::string wasm_local;
  // ... or a slot in the environment of the owning function.
  int env_slot = -1;
};

// A loop that can be the target of 'break' and 'continue'.
struct LoopContext {
  ir::While* loop;
  std::string break_label;
  std::string continue_label;
};

class FunctionGen : public ir::Visitor {
 public:
  enum Kind {
    METHOD,  // Also used for global initializers.
    BLOCK,
    LAMBDA,
  };

  FunctionGen(ModuleGen* module, FunctionGen* outer, Kind kind, ir::Node* node, const std::string& name)
      : module_(module), outer_(outer), kind_(kind), node_(node), name_(name) {
    info_ = module->info(node);
    depth_ = outer == null ? 0 : outer->depth_ + 1;
    // The VM puts the task into the first local of '__entry__task'. See
    // entry.toit. We take it from Task_.current instead.
    is_entry_task_ = kind == METHOD && node == module->entry_point(2);
  }

  // Generates the function and returns its text.
  std::string generate();

  // Visitor.
  void visit_Program(ir::Program* node) { UNREACHABLE(); }
  void visit_Class(ir::Class* node) { UNREACHABLE(); }
  void visit_Field(ir::Field* node) { UNREACHABLE(); }
  void visit_Method(ir::Method* node) { UNREACHABLE(); }
  void visit_MethodInstance(ir::MethodInstance* node) { UNREACHABLE(); }
  void visit_MonitorMethod(ir::MonitorMethod* node) { UNREACHABLE(); }
  void visit_MethodStatic(ir::MethodStatic* node) { UNREACHABLE(); }
  void visit_Constructor(ir::Constructor* node) { UNREACHABLE(); }
  void visit_AdapterStub(ir::AdapterStub* node) { UNREACHABLE(); }
  void visit_MixinStub(ir::MixinStub* node) { UNREACHABLE(); }
  void visit_IsInterfaceOrMixinStub(ir::IsInterfaceOrMixinStub* node) { UNREACHABLE(); }
  void visit_FieldStub(ir::FieldStub* node) { UNREACHABLE(); }
  void visit_Global(ir::Global* node) { UNREACHABLE(); }
  void visit_Builtin(ir::Builtin* node) { UNREACHABLE(); }
  void visit_Local(ir::Local* node) { UNREACHABLE(); }
  void visit_Parameter(ir::Parameter* node) { UNREACHABLE(); }
  void visit_CapturedLocal(ir::CapturedLocal* node) { UNREACHABLE(); }
  void visit_Block(ir::Block* node) { UNREACHABLE(); }
  void visit_Dot(ir::Dot* node) { UNREACHABLE(); }
  void visit_LspSelectionDot(ir::LspSelectionDot* node) { UNREACHABLE(); }
  void visit_Expression(ir::Expression* node) { UNREACHABLE(); }
  void visit_Reference(ir::Reference* node) { UNREACHABLE(); }
  void visit_Assignment(ir::Assignment* node) { UNREACHABLE(); }
  void visit_Literal(ir::Literal* node) { UNREACHABLE(); }
  void visit_Call(ir::Call* node) { UNREACHABLE(); }
  void visit_ReferenceClass(ir::ReferenceClass* node) { UNREACHABLE(); }
  void visit_ReferenceMethod(ir::ReferenceMethod* node) { UNREACHABLE(); }

  void visit_Code(ir::Code* node);
  void visit_Sequence(ir::Sequence* node);
  void visit_TryFinally(ir::TryFinally* node);
  void visit_If(ir::If* node);
  void visit_Not(ir::Not* node);
  void visit_While(ir::While* node);
  void visit_LoopBranch(ir::LoopBranch* node);
  void visit_Error(ir::Error* node);
  void visit_Nop(ir::Nop* node);
  void visit_FieldLoad(ir::FieldLoad* node);
  void visit_FieldStore(ir::FieldStore* node);
  void visit_Super(ir::Super* node);
  void visit_CallConstructor(ir::CallConstructor* node);
  void visit_CallStatic(ir::CallStatic* node);
  void visit_Lambda(ir::Lambda* node);
  void visit_CallVirtual(ir::CallVirtual* node);
  void visit_CallBlock(ir::CallBlock* node);
  void visit_CallBuiltin(ir::CallBuiltin* node);
  void visit_Typecheck(ir::Typecheck* node);
  void visit_Return(ir::Return* node);
  void visit_ReferenceLocal(ir::ReferenceLocal* node);
  void visit_ReferenceBlock(ir::ReferenceBlock* node);
  void visit_ReferenceGlobal(ir::ReferenceGlobal* node);
  void visit_LogicalBinary(ir::LogicalBinary* node);
  void visit_AssignmentLocal(ir::AssignmentLocal* node);
  void visit_AssignmentGlobal(ir::AssignmentGlobal* node);
  void visit_AssignmentDefine(ir::AssignmentDefine* node);
  void visit_LiteralNull(ir::LiteralNull* node);
  void visit_LiteralUndefined(ir::LiteralUndefined* node);
  void visit_LiteralInteger(ir::LiteralInteger* node);
  void visit_LiteralFloat(ir::LiteralFloat* node);
  void visit_LiteralString(ir::LiteralString* node);
  void visit_LiteralByteArray(ir::LiteralByteArray* node);
  void visit_LiteralBoolean(ir::LiteralBoolean* node);
  void visit_PrimitiveInvocation(ir::PrimitiveInvocation* node);

 private:
  ModuleGen* module_;
  FunctionGen* outer_;
  Kind kind_;
  ir::Node* node_;
  std::string name_;
  FunctionInfo* info_;
  int depth_;

  std::string body_;
  int indentation_ = 2;
  std::vector<std::string> local_declarations_;
  int local_counter_ = 0;
  int label_counter_ = 0;
  bool for_value_ = false;
  bool is_entry_task_ = false;
  std::map<ir::Local*, LocalLocation> locals_;
  std::vector<LoopContext> loops_;

  bool is_for_value() const { return for_value_; }
  bool is_for_effect() const { return !for_value_; }

  void emit(const std::string& instruction) {
    body_.append(indentation_, ' ');
    body_ += instruction;
    body_ += '\n';
  }
  void emit(const char* instruction) { emit(std::string(instruction)); }
  void indent() { indentation_ += 2; }
  void dedent() { indentation_ -= 2; }

  std::string new_local(const std::string& type) {
    std::string name = format("$t%d", local_counter_++);
    local_declarations_.push_back(format("(local %s %s)", name.c_str(), type.c_str()));
    return name;
  }
  std::string new_label(const char* prefix) {
    return format("$%s%d", prefix, label_counter_++);
  }

  void visit_for_value(ir::Node* node) {
    bool saved = for_value_;
    for_value_ = true;
    node->accept(this);
    for_value_ = saved;
  }
  void visit_for_effect(ir::Node* node) {
    bool saved = for_value_;
    for_value_ = false;
    node->accept(this);
    for_value_ = saved;
  }
  // Leaves an i32 that is non-zero if the expression is truthy.
  void visit_for_condition(ir::Expression* node);

  // Pushes null if a value is needed.
  void push_null_if_for_value() {
    if (is_for_value()) emit("ref.null none");
  }
  // Pushes the given boolean object.
  void push_boolean(bool value) {
    emit(value ? "global.get $true" : "global.get $false");
  }
  // Converts the i32 on the stack to a boolean object.
  void i32_to_boolean() {
    emit("if (result eqref)");
    indent(); emit("global.get $true"); dedent();
    emit("else");
    indent(); emit("global.get $false"); dedent();
    emit("end");
  }

  // Locals.
  void bind_parameter(ir::Parameter* parameter, const std::string& wasm_local);
  LocalLocation* location(ir::Local* local);
  // Pushes the environment of the function at the given depth (relative to
  // this function) as a (ref null $Env).
  void push_env_at_depth(int depth);
  void load_local(ir::Local* local, int block_depth);
  // Stores the value in the given WebAssembly local into the Toit local.
  void store_local(ir::Local* local, int block_depth, const std::string& value);

  // Calls.
  void call_function(const std::string& name, int arity, bool is_tail_call);
  void push_padding(int count) {
    for (int i = 0; i < count; i++) emit("ref.null none");
  }
  void call_code_failure(bool is_block, int expected, const std::string& provided);
  void generate_intrinsic(ir::PrimitiveInvocation* node);
  bool generate_fast_virtual(ir::CallVirtual* node);
  // Emits a virtual call with the receiver and arguments in the given
  // locals. Leaves the result on the stack.
  void emit_virtual_call(ir::CallVirtual* node, const std::vector<std::string>& locals);
  // Emits the fast path for binary operations on small integers. Leaves an
  // eqref (or an i32 for conditions) on the stack. Returns false if there is
  // no fast path for the operation.
  bool emit_smi_binary(ir::CallVirtual* node, bool for_condition);
  bool is_smi_comparison(ir::Expression* node);

  // Function bodies.
  void generate_prologue();
  std::string generate_block_or_lambda(ir::Code* code);
};

// ---------------------------------------------------------------------------
// Function bodies.

void FunctionGen::bind_parameter(ir::Parameter* parameter, const std::string& wasm_local) {
  auto probe = info_->env_slot_index.find(parameter);
  if (probe != info_->env_slot_index.end()) {
    // The prologue copies the parameter into the environment.
    locals_[parameter].env_slot = probe->second;
  } else {
    locals_[parameter].wasm_local = wasm_local;
  }
}

LocalLocation* FunctionGen::location(ir::Local* local) {
  auto probe = locals_.find(local);
  if (probe != locals_.end()) return &probe->second;
  // Locals are bound when they are defined. The handler parameters of
  // try/finally are bound by the TryFinally node.
  FATAL("unbound local '%s' in %s", local->name().c_str(), name_.c_str());
}

std::string FunctionGen::generate() {
  std::string params_comment;
  std::string type;
  ir::Expression* body = null;
  std::vector<std::pair<ir::Parameter*, std::string>> env_parameters;

  if (kind_ == METHOD) {
    auto method = node_->as_Method();
    int arity = method->is_Global() ? 0 : method->plain_shape().arity();
    type = module_->function_type(arity);
    for (auto parameter : method->parameters()) {
      bind_parameter(parameter, format("%d", parameter->index()));
    }
    body = method->body();
  } else if (kind_ == BLOCK) {
    auto code = node_->as_Code();
    type = "$BlockFn";
    // Parameter 0 is the block itself, parameter 1 the number of passed
    // arguments. The Toit parameters start at index 1, since index 0 is the
    // implicit block parameter.
    for (auto parameter : code->parameters()) {
      bind_parameter(parameter, format("%d", parameter->index() + 1));
    }
    body = code->body();
  } else {
    auto code = node_->as_Code();
    type = "$LambdaFn";
    // Parameter 0 contains the captured values, parameter 1 the number of
    // passed arguments. The captured values are the last parameters of the
    // code.
    int user_arity = code->parameters().length() - code->captured_count();
    for (int i = 0; i < user_arity; i++) {
      auto parameter = code->parameters()[i];
      ASSERT(parameter->index() == i);
      bind_parameter(parameter, format("%d", i + 2));
    }
    body = code->body();
  }

  generate_prologue();

  bool is_code = kind_ != METHOD;
  if (info_->is_nlr_target) {
    // Non-local returns from blocks throw the environment of this function
    // together with the value.
    std::string handler = new_label("nlr");
    std::string exception = new_local("exnref");
    std::string value = new_local("eqref");
    emit(format("block %s (result (ref $Env) eqref exnref)", handler.c_str()));
    indent();
    emit(format("try_table (catch_ref $nlr %s)", handler.c_str()));
    indent();
    if (is_code) {
      visit_for_value(body);
    } else {
      visit_for_effect(body);
      emit("ref.null none");
    }
    emit("return");
    dedent();
    emit("end");
    emit("unreachable");
    dedent();
    emit("end");
    emit(format("local.set %s", exception.c_str()));
    emit(format("local.set %s", value.c_str()));
    emit("local.get $env");
    emit("ref.eq");
    emit("if");
    indent();
    emit(format("local.get %s", value.c_str()));
    emit("return");
    dedent();
    emit("end");
    emit(format("local.get %s", exception.c_str()));
    emit("throw_ref");
  } else if (is_code) {
    visit_for_value(body);
  } else {
    visit_for_effect(body);
    // Methods return null if they don't have an explicit return.
    emit("ref.null none");
  }

  std::string result = format("(func %s (type %s)\n", name_.c_str(), type.c_str());
  for (auto& declaration : local_declarations_) {
    result += "  " + declaration + "\n";
  }
  result += body_;
  result += ")\n";
  return result;
}

void FunctionGen::generate_prologue() {
  std::string prologue;
  std::swap(prologue, body_);

  if (kind_ == BLOCK || kind_ == LAMBDA) {
    auto code = node_->as_Code();
    int user_arity = code->parameters().length() - code->captured_count();
    // Blocks and lambdas may be called with more arguments than they take,
    // but not with fewer.
    emit("local.get 1");
    emit(format("i32.const %d", user_arity));
    emit("i32.lt_s");
    emit("if");
    indent();
    if (kind_ == BLOCK) {
      // The interpreter counts the block itself as argument.
      call_code_failure(true, user_arity + 1, "1");
    } else {
      call_code_failure(false, user_arity, "1");
    }
    dedent();
    emit("end");
  }

  std::map<ir::Parameter*, std::string> captured_sources;
  if (kind_ == LAMBDA) {
    // Unpack the captured values. See 'lambda__' in objects.toit.
    auto code = node_->as_Code();
    int captured_count = code->captured_count();
    int user_arity = code->parameters().length() - captured_count;
    for (int i = 0; i < captured_count; i++) {
      auto parameter = code->parameters()[user_arity + i];
      std::string local = new_local("eqref");
      if (captured_count == 1) {
        // A single captured value is only wrapped if it is an array.
        emit("local.get 0");
        emit("ref.test (ref $Array)");
        emit("if (result eqref)");
        indent();
        emit("local.get 0");
        emit("ref.cast (ref $Array)");
        emit("struct.get $Array $values");
        emit("i32.const 0");
        emit("array.get $Values");
        dedent();
        emit("else");
        indent();
        emit("local.get 0");
        dedent();
        emit("end");
      } else {
        emit("local.get 0");
        emit("ref.cast (ref $Array)");
        emit("struct.get $Array $values");
        emit(format("i32.const %d", i));
        emit("array.get $Values");
      }
      emit(format("local.set %s", local.c_str()));
      captured_sources[parameter] = local;
      bind_parameter(parameter, local);
    }
  }

  if (info_->has_env) {
    // Allocate the environment. Its parent is the environment of the
    // function that created this block.
    int env_type = module_->register_env_type(static_cast<int>(info_->env_slots.size()));
    info_->env_type = env_type;
    std::string type = module_->env_type(env_type);
    local_declarations_.push_back(format("(local $env (ref %s))", type.c_str()));
    if (kind_ == BLOCK) {
      emit("local.get 0");
      emit("struct.get $Block $env");
    } else {
      emit("ref.null none");
    }
    for (size_t i = 0; i < info_->env_slots.size(); i++) {
      emit("ref.null none");
    }
    emit(format("struct.new %s", type.c_str()));
    emit("local.set $env");
  } else {
    ASSERT(info_->env_slots.empty());
  }

  // Copy the parameters that live in the environment.
  std::vector<ir::Parameter*> parameters;
  if (kind_ == METHOD) {
    for (auto parameter : node_->as_Method()->parameters()) parameters.push_back(parameter);
  } else {
    for (auto parameter : node_->as_Code()->parameters()) parameters.push_back(parameter);
  }
  for (auto parameter : parameters) {
    auto probe = info_->env_slot_index.find(parameter);
    if (probe == info_->env_slot_index.end()) continue;
    std::string source;
    if (kind_ == METHOD) {
      source = format("%d", parameter->index());
    } else if (kind_ == BLOCK) {
      source = format("%d", parameter->index() + 1);
    } else {
      auto code = node_->as_Code();
      int user_arity = code->parameters().length() - code->captured_count();
      if (parameter->index() < user_arity) {
        source = format("%d", parameter->index() + 2);
      } else {
        // Captured values have been unpacked into a local.
        source = captured_sources[parameter];
      }
    }
    emit("local.get $env");
    emit(format("local.get %s", source.c_str()));
    emit(format("struct.set %s %d", module_->env_type(info_->env_type).c_str(), probe->second + 1));
    locals_[parameter].wasm_local = "";
    locals_[parameter].env_slot = probe->second;
  }

  std::swap(prologue, body_);
  body_ = prologue + body_;
}

void FunctionGen::push_env_at_depth(int depth) {
  ASSERT(depth >= 1);
  ASSERT(kind_ == BLOCK);
  emit("local.get 0");
  emit("struct.get $Block $env");
  for (int i = 1; i < depth; i++) {
    emit("struct.get $Env $parent");
  }
}

void FunctionGen::load_local(ir::Local* local, int block_depth) {
  if (block_depth == 0) {
    auto location = this->location(local);
    if (location->env_slot >= 0) {
      emit("local.get $env");
      emit(format("struct.get %s %d", module_->env_type(info_->env_type).c_str(), location->env_slot + 1));
    } else {
      emit(format("local.get %s", location->wasm_local.c_str()));
    }
    return;
  }
  FunctionGen* owner = this;
  for (int i = 0; i < block_depth; i++) owner = owner->outer_;
  auto probe = owner->info_->env_slot_index.find(local);
  ASSERT(probe != owner->info_->env_slot_index.end());
  std::string type = module_->env_type(owner->info_->env_type);
  push_env_at_depth(block_depth);
  emit(format("ref.cast (ref %s)", type.c_str()));
  emit(format("struct.get %s %d", type.c_str(), probe->second + 1));
}

void FunctionGen::store_local(ir::Local* local, int block_depth, const std::string& value) {
  if (block_depth == 0) {
    auto location = this->location(local);
    if (location->env_slot >= 0) {
      emit("local.get $env");
      emit(format("local.get %s", value.c_str()));
      emit(format("struct.set %s %d", module_->env_type(info_->env_type).c_str(), location->env_slot + 1));
    } else {
      emit(format("local.get %s", value.c_str()));
      emit(format("local.set %s", location->wasm_local.c_str()));
    }
    return;
  }
  FunctionGen* owner = this;
  for (int i = 0; i < block_depth; i++) owner = owner->outer_;
  auto probe = owner->info_->env_slot_index.find(local);
  ASSERT(probe != owner->info_->env_slot_index.end());
  std::string type = module_->env_type(owner->info_->env_type);
  push_env_at_depth(block_depth);
  emit(format("ref.cast (ref %s)", type.c_str()));
  emit(format("local.get %s", value.c_str()));
  emit(format("struct.set %s %d", type.c_str(), probe->second + 1));
}

void FunctionGen::call_code_failure(bool is_block, int expected, const std::string& provided_local) {
  emit(is_block ? "global.get $true" : "global.get $false");
  emit(format("i32.const %d", expected));
  emit("ref.i31");
  emit(format("local.get %s", provided_local.c_str()));
  if (is_block) {
    emit("i32.const 1");
    emit("i32.add");
  }
  emit("ref.i31");
  emit("i32.const -1");
  emit("ref.i31");
  emit("call $entry.code_failure");
  emit("unreachable");
}

// ---------------------------------------------------------------------------
// Expressions.

void FunctionGen::visit_Error(ir::Error* node) {
  // The program is compiled with --force, and has errors.
  emit("unreachable");
}

void FunctionGen::visit_Nop(ir::Nop* node) {
  push_null_if_for_value();
}

void FunctionGen::visit_Super(ir::Super* node) {
  if (node->expression() != null) {
    node->expression()->accept(this);
  } else {
    push_null_if_for_value();
  }
}

void FunctionGen::visit_Sequence(ir::Sequence* node) {
  auto expressions = node->expressions();
  int length = expressions.length();
  for (int i = 0; i < length - 1; i++) {
    visit_for_effect(expressions[i]);
  }
  if (length > 0) {
    expressions[length - 1]->accept(this);
  } else {
    push_null_if_for_value();
  }
}

void FunctionGen::visit_for_condition(ir::Expression* node) {
  if (node->is_LiteralNull()) {
    emit("i32.const 0");
    return;
  }
  if (node->is_LiteralBoolean()) {
    emit(format("i32.const %d", node->as_LiteralBoolean()->value() ? 1 : 0));
    return;
  }
  if (node->is_Not()) {
    visit_for_condition(node->as_Not()->value());
    emit("i32.eqz");
    return;
  }
  if (node->is_LogicalBinary()) {
    auto logical = node->as_LogicalBinary();
    visit_for_condition(logical->left());
    emit("if (result i32)");
    indent();
    if (logical->op() == ir::LogicalBinary::AND) {
      visit_for_condition(logical->right());
    } else {
      emit("i32.const 1");
    }
    dedent();
    emit("else");
    indent();
    if (logical->op() == ir::LogicalBinary::AND) {
      emit("i32.const 0");
    } else {
      visit_for_condition(logical->right());
    }
    dedent();
    emit("end");
    return;
  }
  if (node->is_CallBuiltin() && node->as_CallBuiltin()->target()->kind() == ir::Builtin::IDENTICAL) {
    auto arguments = node->as_CallBuiltin()->arguments();
    if (arguments[0]->is_LiteralNull() || arguments[1]->is_LiteralNull()) {
      visit_for_value(arguments[arguments[0]->is_LiteralNull() ? 1 : 0]);
      emit("ref.is_null");
      return;
    }
    visit_for_value(arguments[0]);
    visit_for_value(arguments[1]);
    emit("call $identical");
    return;
  }
  if (is_smi_comparison(node)) {
    emit_smi_binary(node->as_CallVirtual(), true);
    return;
  }
  visit_for_value(node);
  emit("call $truthy");
}

void FunctionGen::visit_If(ir::If* node) {
  visit_for_condition(node->condition());
  emit(is_for_value() ? "if (result eqref)" : "if");
  indent();
  node->yes()->accept(this);
  dedent();
  emit("else");
  indent();
  node->no()->accept(this);
  dedent();
  emit("end");
}

void FunctionGen::visit_Not(ir::Not* node) {
  if (is_for_effect()) {
    visit_for_effect(node->value());
    return;
  }
  visit_for_condition(node->value());
  emit("i32.eqz");
  i32_to_boolean();
}

void FunctionGen::visit_LogicalBinary(ir::LogicalBinary* node) {
  bool is_and = node->op() == ir::LogicalBinary::AND;
  if (is_for_effect()) {
    visit_for_condition(node->left());
    if (!is_and) emit("i32.eqz");
    emit("if");
    indent();
    visit_for_effect(node->right());
    dedent();
    emit("end");
    return;
  }
  std::string left = new_local("eqref");
  visit_for_value(node->left());
  emit(format("local.tee %s", left.c_str()));
  emit("call $truthy");
  emit("if (result eqref)");
  indent();
  if (is_and) {
    visit_for_value(node->right());
  } else {
    emit(format("local.get %s", left.c_str()));
  }
  dedent();
  emit("else");
  indent();
  if (is_and) {
    emit(format("local.get %s", left.c_str()));
  } else {
    visit_for_value(node->right());
  }
  dedent();
  emit("end");
}

void FunctionGen::visit_While(ir::While* node) {
  LoopContext loop;
  loop.loop = node;
  loop.break_label = new_label("break");
  loop.continue_label = new_label("continue");
  std::string top = new_label("loop");
  bool is_nl_target = info_->nl_branch_loops.count(node) != 0;

  emit(format("block %s", loop.break_label.c_str()));
  indent();
  emit(format("loop %s", top.c_str()));
  indent();
  visit_for_condition(node->condition());
  emit("i32.eqz");
  emit(format("br_if %s", loop.break_label.c_str()));
  emit(format("block %s", loop.continue_label.c_str()));
  indent();
  loops_.push_back(loop);
  int loop_index = static_cast<int>(loops_.size()) - 1;
  if (is_nl_target) {
    // Blocks in the body may break or continue this loop. They throw the
    // environment and the loop index (shifted left by one, with the lowest
    // bit set for breaks).
    std::string handler = new_label("nlbr");
    std::string exception = new_local("exnref");
    std::string code = new_local("i32");
    emit(format("block %s (result (ref $Env) i32 exnref)", handler.c_str()));
    indent();
    emit(format("try_table (catch_ref $nlbr %s)", handler.c_str()));
    indent();
    visit_for_effect(node->body());
    dedent();
    emit("end");
    emit(format("br %s", loop.continue_label.c_str()));
    dedent();
    emit("end");
    emit(format("local.set %s", exception.c_str()));
    emit(format("local.set %s", code.c_str()));
    emit("local.get $env");
    emit("ref.eq");
    emit(format("local.get %s", code.c_str()));
    emit("i32.const 1");
    emit("i32.shr_u");
    emit(format("i32.const %d", loop_index));
    emit("i32.eq");
    emit("i32.and");
    emit("i32.eqz");
    emit("if");
    indent();
    emit(format("local.get %s", exception.c_str()));
    emit("throw_ref");
    dedent();
    emit("end");
    emit(format("local.get %s", code.c_str()));
    emit("i32.const 1");
    emit("i32.and");
    emit(format("br_if %s", loop.break_label.c_str()));
  } else {
    visit_for_effect(node->body());
  }
  loops_.pop_back();
  dedent();
  emit("end");
  visit_for_effect(node->update());
  emit(format("br %s", top.c_str()));
  dedent();
  emit("end");
  dedent();
  emit("end");
  push_null_if_for_value();
}

void FunctionGen::visit_LoopBranch(ir::LoopBranch* node) {
  if (node->block_depth() == 0) {
    ASSERT(!loops_.empty());
    auto& loop = loops_.back();
    emit(format("br %s", node->is_break() ? loop.break_label.c_str() : loop.continue_label.c_str()));
    return;
  }
  FunctionGen* owner = this;
  for (int i = 0; i < node->block_depth(); i++) owner = owner->outer_;
  ASSERT(!owner->loops_.empty());
  int loop_index = static_cast<int>(owner->loops_.size()) - 1;
  push_env_at_depth(node->block_depth());
  emit("ref.as_non_null");
  emit(format("i32.const %d", (loop_index << 1) | (node->is_break() ? 1 : 0)));
  emit("throw $nlbr");
}

void FunctionGen::visit_Return(ir::Return* node) {
  int depth = node->depth();
  int target_depth = depth == -1 ? depth_ : depth;
  if (target_depth == 0) {
    auto value = node->value();
    if (value->is_CallStatic() && value->as_CallStatic()->is_tail_call() &&
        !value->is_CallConstructor() && !value->is_Lambda() && kind_ == METHOD) {
      // Tail call.
      auto call = value->as_CallStatic();
      for (auto argument : call->arguments()) visit_for_value(argument);
      auto target = call->target()->target();
      emit(format("return_call %s", module_->function_name(target).c_str()));
      return;
    }
    visit_for_value(value);
    emit("return");
    return;
  }
  // Non-local return.
  push_env_at_depth(target_depth);
  emit("ref.as_non_null");
  visit_for_value(node->value());
  emit("throw $nlr");
}

void FunctionGen::visit_Code(ir::Code* node) {
  if (is_for_effect()) return;
  if (node->is_block()) {
    std::string name = module_->new_block_name(name_);
    FunctionGen gen(module_, this, BLOCK, node, name);
    module_->add_function(gen.generate());
    module_->declare_function_reference(name);
    emit(format("ref.func %s", name.c_str()));
    emit("local.get $env");
    emit("struct.new $Block");
  } else {
    std::string name = format("$l.%s", name_.c_str() + 1);
    name = module_->new_block_name(name);
    FunctionGen gen(module_, null, LAMBDA, node, name);
    module_->add_function(gen.generate());
    int index = module_->new_lambda(name);
    emit(format("i32.const %d", index));
    emit("ref.i31");
  }
}

void FunctionGen::visit_TryFinally(ir::TryFinally* node) {
  // The body is a block that we call.
  std::string body = new_local("(ref null $Block)");
  visit_for_value(node->body());
  emit("ref.cast (ref $Block)");
  emit(format("local.set %s", body.c_str()));

  std::string exception = new_local("exnref");
  std::string reason = new_local("eqref");
  std::string value = new_local("eqref");
  std::string run_handler = new_label("handler");
  std::string thrown = new_label("thrown");
  std::string other = new_label("other");

  emit(format("block %s", run_handler.c_str()));
  indent();
  emit(format("block %s (result eqref exnref)", thrown.c_str()));
  indent();
  emit(format("block %s (result exnref)", other.c_str()));
  indent();
  emit(format("try_table (catch_ref $throw %s) (catch_all_ref %s)", thrown.c_str(), other.c_str()));
  indent();
  emit(format("local.get %s", body.c_str()));
  emit("ref.as_non_null");
  emit("i32.const 0");
  push_padding(module_->max_block_arity());
  emit(format("local.get %s", body.c_str()));
  emit("struct.get $Block $fn");
  emit("call_ref $BlockFn");
  emit("drop");
  dedent();
  emit("end");
  // Normal completion.
  emit("ref.null exn");
  emit(format("local.set %s", exception.c_str()));
  emit(format("i32.const %d", -1));
  emit("ref.i31");
  emit(format("local.set %s", reason.c_str()));
  emit(format("br %s", run_handler.c_str()));
  dedent();
  emit("end");
  // Unwinding because of a non-local return or branch.
  emit(format("local.set %s", exception.c_str()));
  emit("i32.const 0");
  emit("ref.i31");
  emit(format("local.set %s", reason.c_str()));
  emit(format("br %s", run_handler.c_str()));
  dedent();
  emit("end");
  // Unwinding because of a Toit exception.
  emit(format("local.set %s", exception.c_str()));
  emit(format("local.set %s", value.c_str()));
  emit(format("i32.const %d", Interpreter::UNWIND_REASON_WHEN_THROWING_EXCEPTION));
  emit("ref.i31");
  emit(format("local.set %s", reason.c_str()));
  dedent();
  emit("end");

  auto handler_parameters = node->handler_parameters();
  if (!handler_parameters.is_empty()) {
    ASSERT(handler_parameters.length() == 2);
    const std::string* sources[] = { &reason, &value };
    for (int i = 0; i < 2; i++) {
      auto local = handler_parameters[i];
      auto probe = info_->env_slot_index.find(local);
      if (probe != info_->env_slot_index.end()) {
        locals_[local].env_slot = probe->second;
        store_local(local, 0, *sources[i]);
      } else {
        locals_[local].wasm_local = *sources[i];
      }
    }
  }
  visit_for_effect(node->handler());

  // Continue unwinding, unless the handler returned.
  std::string done = new_label("done");
  emit(format("block %s", done.c_str()));
  indent();
  emit(format("local.get %s", exception.c_str()));
  emit(format("br_on_null %s", done.c_str()));
  emit("throw_ref");
  dedent();
  emit("end");
  push_null_if_for_value();
}

void FunctionGen::visit_FieldLoad(ir::FieldLoad* node) {
  auto field = node->field();
  std::string type = module_->class_type(field->holder());
  visit_for_value(node->receiver());
  emit(format("ref.cast (ref %s)", type.c_str()));
  emit(format("struct.get %s %d", type.c_str(), field->resolved_index() + 1));
  if (is_for_effect()) emit("drop");
}

void FunctionGen::visit_FieldStore(ir::FieldStore* node) {
  auto field = node->field();
  std::string type = module_->class_type(field->holder());
  visit_for_value(node->receiver());
  emit(format("ref.cast (ref %s)", type.c_str()));
  visit_for_value(node->value());
  if (is_for_value()) {
    std::string value = new_local("eqref");
    emit(format("local.tee %s", value.c_str()));
    emit(format("struct.set %s %d", type.c_str(), field->resolved_index() + 1));
    emit(format("local.get %s", value.c_str()));
  } else {
    emit(format("struct.set %s %d", type.c_str(), field->resolved_index() + 1));
  }
}

void FunctionGen::call_function(const std::string& name, int arity, bool is_tail_call) {
  emit(format("call %s", name.c_str()));
  if (is_for_effect()) emit("drop");
}

void FunctionGen::visit_CallConstructor(ir::CallConstructor* node) {
  auto klass = node->klass();
  std::string type = module_->class_type(klass);
  emit(format("i32.const %d", module_->class_id(klass)));
  for (int i = 0; i < klass->total_field_count(); i++) emit("ref.null none");
  emit(format("struct.new %s", type.c_str()));
  for (auto argument : node->arguments()) visit_for_value(argument);
  auto target = node->target()->target();
  call_function(module_->function_name(target), node->arguments().length() + 1, false);
}

void FunctionGen::visit_CallStatic(ir::CallStatic* node) {
  for (auto argument : node->arguments()) visit_for_value(argument);
  auto target = node->target()->target();
  call_function(module_->function_name(target), node->arguments().length(), false);
}

void FunctionGen::visit_Lambda(ir::Lambda* node) {
  visit_CallStatic(node);
}

void FunctionGen::emit_virtual_call(ir::CallVirtual* node, const std::vector<std::string>& locals) {
  auto shape = node->shape();
  Selector<PlainShape> selector(node->selector(), shape.to_plain_shape());
  int offset = module_->dispatch_table()->dispatch_offset_for(selector);
  ASSERT(offset >= 0);
  for (auto& local : locals) emit(format("local.get %s", local.c_str()));
  emit(format("local.get %s", locals[0].c_str()));
  emit(format("i32.const %d", offset));
  emit("call $dispatch_index");
  emit(format("call_indirect $dispatch (type %s)", module_->function_type(shape.arity()).c_str()));
}

static bool is_smi_binary_opcode(Opcode opcode) {
  switch (opcode) {
    case INVOKE_LT: case INVOKE_GT: case INVOKE_LTE: case INVOKE_GTE:
    case INVOKE_BIT_OR: case INVOKE_BIT_XOR: case INVOKE_BIT_AND:
    case INVOKE_BIT_SHL: case INVOKE_BIT_SHR: case INVOKE_BIT_USHR:
    case INVOKE_ADD: case INVOKE_SUB: case INVOKE_MUL: case INVOKE_DIV: case INVOKE_MOD:
      return true;
    default:
      return false;
  }
}

static bool is_comparison_opcode(Opcode opcode) {
  return opcode == INVOKE_LT || opcode == INVOKE_GT || opcode == INVOKE_LTE || opcode == INVOKE_GTE;
}

bool FunctionGen::is_smi_comparison(ir::Expression* node) {
  if (!node->is_CallVirtual()) return false;
  auto call = node->as_CallVirtual();
  if (call->arguments().length() != 1) return false;
  Selector<PlainShape> selector(call->selector(), call->shape().to_plain_shape());
  if (module_->dispatch_table()->dispatch_offset_for(selector) < 0) return false;
  return is_comparison_opcode(call->opcode());
}

bool FunctionGen::emit_smi_binary(ir::CallVirtual* node, bool for_condition) {
  Opcode opcode = node->opcode();
  if (!is_smi_binary_opcode(opcode) || node->arguments().length() != 1) return false;
  Selector<PlainShape> selector(node->selector(), node->shape().to_plain_shape());
  if (module_->dispatch_table()->dispatch_offset_for(selector) < 0) return false;
  bool is_comparison = is_comparison_opcode(opcode);
  ASSERT(!for_condition || is_comparison);

  std::string a = new_local("eqref");
  std::string b = new_local("eqref");
  std::string x = new_local("i32");
  std::string y = new_local("i32");
  std::string r = new_local("i32");
  visit_for_value(node->receiver());
  emit(format("local.set %s", a.c_str()));
  visit_for_value(node->arguments()[0]);
  emit(format("local.set %s", b.c_str()));

  const char* result_type = for_condition ? "i32" : "eqref";
  std::string slow = new_label("slow");
  std::string done = new_label("done");
  emit(format("block %s (result %s)", done.c_str(), result_type));
  indent();
  emit(format("block %s", slow.c_str()));
  indent();
  // Both must be small integers.
  for (auto pair : { std::make_pair(a, x), std::make_pair(b, y) }) {
    emit(format("local.get %s", pair.first.c_str()));
    emit("ref.test (ref i31)");
    emit("i32.eqz");
    emit(format("br_if %s", slow.c_str()));
    emit(format("local.get %s", pair.first.c_str()));
    emit("ref.cast (ref i31)");
    emit("i31.get_s");
    emit(format("local.set %s", pair.second.c_str()));
  }
  auto push_xy = [&]() {
    emit(format("local.get %s", x.c_str()));
    emit(format("local.get %s", y.c_str()));
  };
  // Leaves the i32 result in 'r' and branches to the slow path if it doesn't
  // fit a small integer.
  auto check_range = [&]() {
    emit(format("local.tee %s", r.c_str()));
    emit("i32.const 0x40000000");
    emit("i32.add");
    emit("i32.const 0");
    emit("i32.lt_s");
    emit(format("br_if %s", slow.c_str()));
    emit(format("local.get %s", r.c_str()));
  };
  auto check_divisor = [&]() {
    emit(format("local.get %s", y.c_str()));
    emit("i32.eqz");
    emit(format("br_if %s", slow.c_str()));
  };
  switch (opcode) {
    case INVOKE_LT: push_xy(); emit("i32.lt_s"); break;
    case INVOKE_GT: push_xy(); emit("i32.gt_s"); break;
    case INVOKE_LTE: push_xy(); emit("i32.le_s"); break;
    case INVOKE_GTE: push_xy(); emit("i32.ge_s"); break;
    case INVOKE_BIT_OR: push_xy(); emit("i32.or"); break;
    case INVOKE_BIT_XOR: push_xy(); emit("i32.xor"); break;
    case INVOKE_BIT_AND: push_xy(); emit("i32.and"); break;
    case INVOKE_ADD: push_xy(); emit("i32.add"); check_range(); break;
    case INVOKE_SUB: push_xy(); emit("i32.sub"); check_range(); break;
    case INVOKE_MUL: {
      // Multiply as 64-bit integers, and check that the result fits.
      std::string wide = new_local("i64");
      emit(format("local.get %s", x.c_str()));
      emit("i64.extend_i32_s");
      emit(format("local.get %s", y.c_str()));
      emit("i64.extend_i32_s");
      emit("i64.mul");
      emit(format("local.tee %s", wide.c_str()));
      emit(format("local.get %s", wide.c_str()));
      emit("i32.wrap_i64");
      emit("i64.extend_i32_s");
      emit("i64.ne");
      emit(format("br_if %s", slow.c_str()));
      emit(format("local.get %s", wide.c_str()));
      emit("i32.wrap_i64");
      check_range();
      break;
    }
    case INVOKE_DIV: check_divisor(); push_xy(); emit("i32.div_s"); check_range(); break;
    case INVOKE_MOD: check_divisor(); push_xy(); emit("i32.rem_s"); break;
    case INVOKE_BIT_SHL:
      // Only shifts that keep all bits.
      emit(format("local.get %s", y.c_str()));
      emit("i32.const 31");
      emit("i32.ge_u");
      emit(format("br_if %s", slow.c_str()));
      push_xy();
      emit("i32.shl");
      emit(format("local.tee %s", r.c_str()));
      emit(format("local.get %s", y.c_str()));
      emit("i32.shr_s");
      emit(format("local.get %s", x.c_str()));
      emit("i32.ne");
      emit(format("br_if %s", slow.c_str()));
      emit(format("local.get %s", r.c_str()));
      check_range();
      break;
    case INVOKE_BIT_SHR:
      emit(format("local.get %s", y.c_str()));
      emit("i32.const 0");
      emit("i32.lt_s");
      emit(format("br_if %s", slow.c_str()));
      emit(format("local.get %s", x.c_str()));
      emit(format("local.get %s", y.c_str()));
      emit("i32.const 31");
      emit(format("local.get %s", y.c_str()));
      emit("i32.const 31");
      emit("i32.lt_u");
      emit("select");
      emit("i32.shr_s");
      break;
    case INVOKE_BIT_USHR:
      // Only non-negative numbers are the same as 64-bit integers.
      emit(format("local.get %s", x.c_str()));
      emit(format("local.get %s", y.c_str()));
      emit("i32.or");
      emit("i32.const 0");
      emit("i32.lt_s");
      emit(format("br_if %s", slow.c_str()));
      emit(format("local.get %s", x.c_str()));
      emit(format("local.get %s", y.c_str()));
      emit("i32.const 31");
      emit(format("local.get %s", y.c_str()));
      emit("i32.const 31");
      emit("i32.lt_u");
      emit("select");
      emit("i32.shr_u");
      break;
    default:
      UNREACHABLE();
  }
  if (!for_condition) {
    if (is_comparison) {
      emit("call $boolean");
    } else {
      emit("ref.i31");
    }
  }
  emit(format("br %s", done.c_str()));
  dedent();
  emit("end");
  // Like the interpreter, compare all numbers directly, and add, subtract,
  // and multiply floats directly. Otherwise call the operator method.
  if (is_comparison) {
    int bit = 0;
    switch (opcode) {
      case INVOKE_LT: bit = Interpreter::COMPARE_FLAG_STRICTLY_LESS; break;
      case INVOKE_LTE: bit = Interpreter::COMPARE_FLAG_LESS_EQUAL; break;
      case INVOKE_GT: bit = Interpreter::COMPARE_FLAG_STRICTLY_GREATER; break;
      case INVOKE_GTE: bit = Interpreter::COMPARE_FLAG_GREATER_EQUAL; break;
      default: UNREACHABLE();
    }
    emit(format("local.get %s", a.c_str()));
    emit(format("local.get %s", b.c_str()));
    emit(format("i32.const %d", bit));
    emit("call $relational_slow");
    emit(format("local.tee %s", r.c_str()));
    emit("i32.const 2");
    emit("i32.ne");
    emit("if");
    indent();
    emit(format("local.get %s", r.c_str()));
    if (!for_condition) emit("call $boolean");
    emit(format("br %s", done.c_str()));
    dedent();
    emit("end");
  } else if (opcode == INVOKE_ADD || opcode == INVOKE_SUB || opcode == INVOKE_MUL) {
    emit(format("local.get %s", a.c_str()));
    emit(format("local.get %s", b.c_str()));
    emit(format("i32.const %d", opcode == INVOKE_ADD ? 0 : (opcode == INVOKE_SUB ? 1 : 2)));
    emit("call $float_arithmetic");
    emit(format("br_on_non_null %s", done.c_str()));
  }
  emit_virtual_call(node, { a, b });
  if (for_condition) emit("call $truthy");
  dedent();
  emit("end");
  return true;
}

bool FunctionGen::generate_fast_virtual(ir::CallVirtual* node) {
  Opcode opcode = node->opcode();
  if (opcode == INVOKE_EQ && node->arguments().length() == 1) {
    // Identical objects are equal, and nothing is equal to null. Numbers
    // are compared directly. Only call the '==' method for other objects.
    std::string a = new_local("eqref");
    std::string b = new_local("eqref");
    visit_for_value(node->receiver());
    emit(format("local.set %s", a.c_str()));
    visit_for_value(node->arguments()[0]);
    emit(format("local.set %s", b.c_str()));
    emit(format("local.get %s", a.c_str()));
    emit(format("local.get %s", b.c_str()));
    emit("call $equals_fast");
    std::string result = new_local("i32");
    emit(format("local.tee %s", result.c_str()));
    emit("i32.const 2");
    emit("i32.eq");
    emit("if (result eqref)");
    indent();
    emit_virtual_call(node, { a, b });
    dedent();
    emit("else");
    indent();
    emit(format("local.get %s", result.c_str()));
    i32_to_boolean();
    dedent();
    emit("end");
    if (is_for_effect()) emit("drop");
    return true;
  }
  Selector<PlainShape> selector(node->selector(), node->shape().to_plain_shape());
  if (module_->dispatch_table()->dispatch_offset_for(selector) < 0) return false;
  if (emit_smi_binary(node, false)) {
    if (is_for_effect()) emit("drop");
    return true;
  }
  if ((opcode == INVOKE_AT && node->arguments().length() == 1) ||
      (opcode == INVOKE_AT_PUT && node->arguments().length() == 2) ||
      (opcode == INVOKE_SIZE && node->arguments().length() == 0)) {
    std::vector<std::string> locals;
    locals.push_back(new_local("eqref"));
    visit_for_value(node->receiver());
    emit(format("local.set %s", locals[0].c_str()));
    for (auto argument : node->arguments()) {
      locals.push_back(new_local("eqref"));
      visit_for_value(argument);
      emit(format("local.set %s", locals.back().c_str()));
    }
    // The runtime has fast paths for arrays, lists, and byte arrays. They
    // return the result and whether the fast path applied.
    std::string done = new_label("done");
    emit(format("block %s (result eqref)", done.c_str()));
    indent();
    for (auto& local : locals) emit(format("local.get %s", local.c_str()));
    if (opcode == INVOKE_AT) {
      emit("call $fast_at");
    } else if (opcode == INVOKE_AT_PUT) {
      emit("call $fast_at_put");
    } else {
      emit("call $fast_size");
    }
    emit(format("br_if %s", done.c_str()));
    emit("drop");
    emit_virtual_call(node, locals);
    dedent();
    emit("end");
    if (is_for_effect()) emit("drop");
    return true;
  }
  return false;
}

void FunctionGen::visit_CallVirtual(ir::CallVirtual* node) {
  if (generate_fast_virtual(node)) return;

  auto shape = node->shape();
  int arity = shape.arity();
  Selector<PlainShape> selector(node->selector(), shape.to_plain_shape());
  int offset = module_->dispatch_table()->dispatch_offset_for(selector);

  std::string receiver = new_local("eqref");
  visit_for_value(node->receiver());
  emit(format("local.tee %s", receiver.c_str()));
  for (auto argument : node->arguments()) visit_for_value(argument);

  if (offset < 0) {
    // No class implements the selector.
    for (int i = 0; i < arity; i++) emit("drop");
    emit(format("local.get %s", receiver.c_str()));
    std::string name = node->selector().c_str();
    if (shape.is_setter()) name += "=";
    int literal = module_->string_literal(name.c_str(), static_cast<int>(name.length()));
    emit("global.get $literals");
    emit(format("i32.const %d", literal));
    emit("array.get $Values");
    emit("call $entry.lookup_failure");
    emit("unreachable");
    return;
  }

  emit(format("local.get %s", receiver.c_str()));
  emit(format("i32.const %d", offset));
  emit("call $dispatch_index");
  emit(format("call_indirect $dispatch (type %s)", module_->function_type(arity).c_str()));
  if (is_for_effect()) emit("drop");
}

void FunctionGen::visit_CallBlock(ir::CallBlock* node) {
  std::string block = new_local("(ref null $Block)");
  visit_for_value(node->target());
  emit("ref.cast (ref $Block)");
  emit(format("local.tee %s", block.c_str()));
  emit("ref.as_non_null");
  auto arguments = node->arguments();
  emit(format("i32.const %d", arguments.length()));
  for (auto argument : arguments) visit_for_value(argument);
  push_padding(module_->max_block_arity() - arguments.length());
  emit(format("local.get %s", block.c_str()));
  emit("struct.get $Block $fn");
  emit("call_ref $BlockFn");
  if (is_for_effect()) emit("drop");
}

void FunctionGen::visit_CallBuiltin(ir::CallBuiltin* node) {
  auto arguments = node->arguments();
  switch (node->target()->kind()) {
    case ir::Builtin::THROW:
      visit_for_value(arguments[0]);
      emit("throw $throw");
      break;

    case ir::Builtin::INVOKE_LAMBDA: {
      // Only used in the 'call' methods of the Lambda class. The receiver is
      // the first parameter and the arguments follow.
      int arity = arguments[0]->as_LiteralInteger()->value();
      std::string type = module_->class_type(module_->lambda_class());
      int arguments_index = module_->lambda_arguments_field()->resolved_index() + 1;
      int method_index = module_->lambda_method_field()->resolved_index() + 1;
      emit("local.get 0");
      emit(format("ref.cast (ref %s)", type.c_str()));
      emit(format("struct.get %s %d", type.c_str(), arguments_index));
      emit(format("i32.const %d", arity));
      for (int i = 0; i < arity; i++) emit(format("local.get %d", i + 1));
      push_padding(module_->max_lambda_arity() - arity);
      emit("local.get 0");
      emit(format("ref.cast (ref %s)", type.c_str()));
      emit(format("struct.get %s %d", type.c_str(), method_index));
      emit("ref.cast (ref i31)");
      emit("i31.get_s");
      emit("return_call_indirect $lambdas (type $LambdaFn)");
      break;
    }

    case ir::Builtin::YIELD:
      emit("call $yield");
      if (is_for_effect()) emit("drop");
      break;

    case ir::Builtin::EXIT:
    case ir::Builtin::DEEP_SLEEP:
      visit_for_value(arguments[0]);
      emit("call $exit");
      emit("unreachable");
      break;

    case ir::Builtin::RESET:
      emit("i32.const 0");
      emit("ref.i31");
      emit("call $exit");
      emit("unreachable");
      break;

    case ir::Builtin::STORE_GLOBAL: {
      std::string value = new_local("eqref");
      emit("global.get $globals");
      visit_for_value(arguments[0]);
      emit("ref.cast (ref i31)");
      emit("i31.get_s");
      visit_for_value(arguments[1]);
      emit(format("local.tee %s", value.c_str()));
      emit("array.set $Values");
      if (is_for_value()) emit(format("local.get %s", value.c_str()));
      break;
    }

    case ir::Builtin::LOAD_GLOBAL:
      emit("global.get $globals");
      visit_for_value(arguments[0]);
      emit("ref.cast (ref i31)");
      emit("i31.get_s");
      emit("array.get $Values");
      if (is_for_effect()) emit("drop");
      break;

    case ir::Builtin::INVOKE_INITIALIZER:
      visit_for_value(arguments[0]);
      emit("ref.cast (ref i31)");
      emit("i31.get_s");
      emit(format("return_call_indirect $initializers (type %s)", module_->function_type(0).c_str()));
      break;

    case ir::Builtin::GLOBAL_ID: {
      auto global = arguments[0]->as_ReferenceGlobal()->target();
      if (is_for_value()) {
        emit(format("i32.const %d", global->global_id()));
        emit("ref.i31");
      }
      break;
    }

    case ir::Builtin::IDENTICAL:
      if (is_for_effect()) {
        visit_for_effect(arguments[0]);
        visit_for_effect(arguments[1]);
      } else {
        visit_for_condition(node);
        i32_to_boolean();
      }
      break;
  }
}

void FunctionGen::visit_Typecheck(ir::Typecheck* node) {
  if (node->type().is_any()) {
    if (node->is_as_check()) {
      node->expression()->accept(this);
    } else if (is_for_value()) {
      visit_for_effect(node->expression());
      push_boolean(true);
    } else {
      visit_for_effect(node->expression());
    }
    return;
  }
  auto klass = node->type().klass();
  bool is_nullable = node->type().is_nullable();
  std::string value = new_local("eqref");
  visit_for_value(node->expression());
  emit(format("local.tee %s", value.c_str()));
  if (node->is_interface_check()) {
    auto call_selector = klass->typecheck_selector();
    Selector<PlainShape> selector(call_selector.name(), call_selector.shape().to_plain_shape());
    int offset = module_->dispatch_table()->dispatch_offset_for(selector);
    emit(format("i32.const %d", offset));
    emit(format("i32.const %d", is_nullable ? 1 : 0));
    emit("call $is_interface");
  } else {
    emit(format("i32.const %d", klass->start_id()));
    emit(format("i32.const %d", klass->end_id()));
    emit(format("i32.const %d", is_nullable ? 1 : 0));
    emit("call $is_class");
  }
  if (node->is_as_check()) {
    emit("i32.eqz");
    emit("if");
    indent();
    emit(format("local.get %s", value.c_str()));
    const char* name = node->type_name().c_str();
    int literal = module_->string_literal(name, strlen(name));
    emit("global.get $literals");
    emit(format("i32.const %d", literal));
    emit("array.get $Values");
    emit("call $entry.as_check_failure");
    emit("unreachable");
    dedent();
    emit("end");
    if (is_for_value()) emit(format("local.get %s", value.c_str()));
  } else if (is_for_value()) {
    i32_to_boolean();
  } else {
    emit("drop");
  }
}

void FunctionGen::visit_ReferenceLocal(ir::ReferenceLocal* node) {
  if (is_for_effect()) return;
  load_local(node->target(), node->block_depth());
}

void FunctionGen::visit_ReferenceBlock(ir::ReferenceBlock* node) {
  if (is_for_effect()) return;
  load_local(node->target(), node->block_depth());
}

void FunctionGen::visit_ReferenceGlobal(ir::ReferenceGlobal* node) {
  auto global = node->target();
  bool is_lazy = node->is_lazy() && global->is_lazy();
  if (is_lazy) {
    emit(format("i32.const %d", global->global_id()));
    emit("call $load_global_lazy");
    if (is_for_effect()) emit("drop");
    return;
  }
  if (is_for_effect()) return;
  emit("global.get $globals");
  emit(format("i32.const %d", global->global_id()));
  emit("array.get $Values");
}

void FunctionGen::visit_AssignmentLocal(ir::AssignmentLocal* node) {
  std::string value = new_local("eqref");
  visit_for_value(node->right());
  emit(format("local.set %s", value.c_str()));
  store_local(node->local(), node->block_depth(), value);
  if (is_for_value()) emit(format("local.get %s", value.c_str()));
}

void FunctionGen::visit_AssignmentGlobal(ir::AssignmentGlobal* node) {
  std::string value = new_local("eqref");
  emit("global.get $globals");
  emit(format("i32.const %d", node->global()->global_id()));
  visit_for_value(node->right());
  emit(format("local.tee %s", value.c_str()));
  emit("array.set $Values");
  if (is_for_value()) emit(format("local.get %s", value.c_str()));
}

void FunctionGen::visit_AssignmentDefine(ir::AssignmentDefine* node) {
  auto local = node->local();
  auto probe = info_->env_slot_index.find(local);
  if (probe != info_->env_slot_index.end()) {
    locals_[local].env_slot = probe->second;
  } else {
    locals_[local].wasm_local = format("$v%d", local_counter_++);
    local_declarations_.push_back(format("(local %s eqref)", locals_[local].wasm_local.c_str()));
  }
  std::string value = new_local("eqref");
  if (is_entry_task_ && node->right()->is_LiteralNull()) {
    is_entry_task_ = false;
    emit("global.get $globals");
    emit(format("i32.const %d", module_->current_task_global()->global_id()));
    emit("array.get $Values");
  } else {
    visit_for_value(node->right());
  }
  emit(format("local.set %s", value.c_str()));
  store_local(local, 0, value);
  if (is_for_value()) emit(format("local.get %s", value.c_str()));
}

void FunctionGen::visit_LiteralNull(ir::LiteralNull* node) {
  push_null_if_for_value();
}

void FunctionGen::visit_LiteralUndefined(ir::LiteralUndefined* node) {
  push_null_if_for_value();
}

void FunctionGen::visit_LiteralInteger(ir::LiteralInteger* node) {
  if (is_for_effect()) return;
  int64 value = node->value();
  if (-(1LL << 30) <= value && value < (1LL << 30)) {
    emit(format("i32.const %d", static_cast<int>(value)));
    emit("ref.i31");
  } else {
    emit(format("global.get %s", module_->large_integer_literal(value).c_str()));
  }
}

void FunctionGen::visit_LiteralFloat(ir::LiteralFloat* node) {
  if (is_for_effect()) return;
  emit(format("global.get %s", module_->float_literal(node->value()).c_str()));
}

void FunctionGen::visit_LiteralString(ir::LiteralString* node) {
  if (is_for_effect()) return;
  int index = module_->string_literal(node->value(), node->length());
  emit("global.get $literals");
  emit(format("i32.const %d", index));
  emit("array.get $Values");
}

void FunctionGen::visit_LiteralByteArray(ir::LiteralByteArray* node) {
  if (is_for_effect()) return;
  int index = module_->byte_array_literal(node->data());
  emit("global.get $literals");
  emit(format("i32.const %d", index));
  emit("array.get $Values");
}

void FunctionGen::visit_LiteralBoolean(ir::LiteralBoolean* node) {
  if (is_for_effect()) return;
  push_boolean(node->value());
}

void FunctionGen::generate_intrinsic(ir::PrimitiveInvocation* node) {
  // Intrinsics make a method loop over a block. The parameters are the
  // receiver and the block (see 'repeat' in numbers.toit and 'do_' in
  // collections.toit).
  auto primitive = node->primitive();
  if (primitive == Symbols::smi_repeat) {
    // this.repeat [block]: calls the block with 0..this-1.
    std::string index = new_local("i32");
    std::string limit = new_local("i32");
    std::string block = new_local("(ref null $Block)");
    std::string done = new_label("done");
    std::string loop = new_label("loop");
    emit("local.get 0");
    emit("ref.cast (ref i31)");
    emit("i31.get_s");
    emit(format("local.set %s", limit.c_str()));
    emit("local.get 1");
    emit("ref.cast (ref $Block)");
    emit(format("local.set %s", block.c_str()));
    emit(format("block %s", done.c_str()));
    indent();
    emit(format("loop %s", loop.c_str()));
    indent();
    emit(format("local.get %s", index.c_str()));
    emit(format("local.get %s", limit.c_str()));
    emit("i32.ge_s");
    emit(format("br_if %s", done.c_str()));
    emit(format("local.get %s", block.c_str()));
    emit("ref.as_non_null");
    emit("i32.const 1");
    emit(format("local.get %s", index.c_str()));
    emit("ref.i31");
    push_padding(module_->max_block_arity() - 1);
    emit(format("local.get %s", block.c_str()));
    emit("struct.get $Block $fn");
    emit("call_ref $BlockFn");
    emit("drop");
    emit(format("local.get %s", index.c_str()));
    emit("i32.const 1");
    emit("i32.add");
    emit(format("local.set %s", index.c_str()));
    emit(format("br %s", loop.c_str()));
    dedent();
    emit("end");
    dedent();
    emit("end");
    emit("ref.null none");
    emit("return");
  } else if (primitive == Symbols::array_do) {
    // Array_.do_ end [block]: calls the block with the first 'end'
    // elements of the array.
    std::string index = new_local("i32");
    std::string limit = new_local("i32");
    std::string values = new_local("(ref null $Values)");
    std::string block = new_local("(ref null $Block)");
    std::string done = new_label("done");
    std::string loop = new_label("loop");
    emit("local.get 0");
    emit("ref.cast (ref $Array)");
    emit("struct.get $Array $values");
    emit(format("local.set %s", values.c_str()));
    emit("local.get 1");
    emit("ref.cast (ref i31)");
    emit("i31.get_s");
    emit(format("local.set %s", limit.c_str()));
    emit("local.get 2");
    emit("ref.cast (ref $Block)");
    emit(format("local.set %s", block.c_str()));
    emit(format("block %s", done.c_str()));
    indent();
    emit(format("loop %s", loop.c_str()));
    indent();
    emit(format("local.get %s", index.c_str()));
    emit(format("local.get %s", limit.c_str()));
    emit("i32.ge_s");
    emit(format("br_if %s", done.c_str()));
    emit(format("local.get %s", block.c_str()));
    emit("ref.as_non_null");
    emit("i32.const 1");
    emit(format("local.get %s", values.c_str()));
    emit(format("local.get %s", index.c_str()));
    emit("array.get $Values");
    push_padding(module_->max_block_arity() - 1);
    emit(format("local.get %s", block.c_str()));
    emit("struct.get $Block $fn");
    emit("call_ref $BlockFn");
    emit("drop");
    emit(format("local.get %s", index.c_str()));
    emit("i32.const 1");
    emit("i32.add");
    emit(format("local.set %s", index.c_str()));
    emit(format("br %s", loop.c_str()));
    dedent();
    emit("end");
    dedent();
    emit("end");
    emit("ref.null none");
    emit("return");
  } else {
    // The other intrinsics are optimizations. Their fallback code implements
    // them.
    if (is_for_value()) emit("call $unimplemented_error");
  }
}

void FunctionGen::visit_PrimitiveInvocation(ir::PrimitiveInvocation* node) {
  if (node->module() == Symbols::intrinsics) {
    generate_intrinsic(node);
    return;
  }
  // Primitive names are kebab-case in Toit, but snake-case in the VM.
  std::string primitive_name = node->primitive().c_str();
  std::replace(primitive_name.begin(), primitive_name.end(), '-', '_');
  std::string name = format("$prim.%s.%s", node->module().c_str(), primitive_name.c_str());
  if (!module_->has_primitive(name)) {
    // The error must be a string, as it is used as such by the failure code.
    std::string description = format("%s.%s", node->module().c_str(), node->primitive().c_str());
    int literal = module_->string_literal(description.c_str(), static_cast<int>(description.length()));
    emit("global.get $literals");
    emit(format("i32.const %d", literal));
    emit("array.get $Values");
    emit("call $missing_primitive");
    if (is_for_effect()) emit("drop");
    return;
  }
  auto method = node_->as_Method();
  std::string failed = new_label("failed");
  emit(format("block %s (result (ref $Failure))", failed.c_str()));
  indent();
  // The parameters may have been assigned (for example with a default
  // value) and may live in the environment of the method.
  for (auto parameter : method->parameters()) load_local(parameter, 0);
  emit(format("call %s", name.c_str()));
  emit(format("br_on_cast %s eqref (ref $Failure)", failed.c_str()));
  emit("return");
  dedent();
  emit("end");
  emit("struct.get $Failure 0");
  if (is_for_effect()) emit("drop");
}

// ---------------------------------------------------------------------------
// Module generation.

int ModuleGen::string_literal(const char* data, int length) {
  std::string key(data, length);
  auto probe = string_literal_ids_.find(key);
  if (probe != string_literal_ids_.end()) return probe->second;
  int offset = static_cast<int>(string_data_.size());
  string_data_.append(data, length);
  int id = static_cast<int>(string_literals_.size() + byte_array_literals_.size());
  // Strings and byte arrays share the literal array. Byte arrays are marked
  // by a negative length.
  string_literals_.push_back(std::make_pair(offset, length));
  string_literal_ids_[key] = id;
  return id;
}

int ModuleGen::byte_array_literal(List<uint8> data) {
  int offset = static_cast<int>(string_data_.size());
  string_data_.append(reinterpret_cast<const char*>(data.data()), data.length());
  int id = static_cast<int>(string_literals_.size() + byte_array_literals_.size());
  string_literals_.push_back(std::make_pair(offset, -1 - data.length()));
  return id;
}

std::string ModuleGen::float_literal(double value) {
  uint64 bits;
  memcpy(&bits, &value, sizeof(bits));
  auto probe = float_literals_.find(bits);
  if (probe != float_literals_.end()) return probe->second;
  std::string name = format("$float%d", static_cast<int>(float_literals_.size()));
  std::string text;
  if (std::isnan(value)) {
    text = format("%snan:0x%llx", (bits >> 63) ? "-" : "",
                  static_cast<unsigned long long>(bits & 0xfffffffffffffULL));
  } else if (std::isinf(value)) {
    text = value < 0 ? "-inf" : "inf";
  } else {
    text = format("%a", value);
  }
  constant_globals_.push_back(format("(global %s (ref $Float) (struct.new $Float (global.get $cid.float_) (f64.const %s)))",
                                     name.c_str(), text.c_str()));
  float_literals_[bits] = name;
  return name;
}

std::string ModuleGen::large_integer_literal(int64 value) {
  auto probe = large_integer_literals_.find(value);
  if (probe != large_integer_literals_.end()) return probe->second;
  std::string name = format("$int%d", static_cast<int>(large_integer_literals_.size()));
  constant_globals_.push_back(format("(global %s (ref $LargeInt) (struct.new $LargeInt (global.get $cid.LargeInteger_) (i64.const %lld)))",
                                     name.c_str(), static_cast<long long>(value)));
  large_integer_literals_[value] = name;
  return name;
}

// Returns the runtime. For development, the TOIT_WASM_RUNTIME environment
// variable can point to a runtime file that is used instead of the embedded
// one.
static std::string runtime_text() {
  const char* path = getenv("TOIT_WASM_RUNTIME");
  if (path == null || path[0] == '\0') {
    return std::string(reinterpret_cast<const char*>(toit_wasm_runtime_wat), toit_wasm_runtime_wat_len);
  }
  FILE* file = fopen(path, "rb");
  if (file == null) FATAL("could not open '%s'", path);
  std::string result;
  char buffer[4096];
  size_t read;
  while ((read = fread(buffer, 1, sizeof(buffer), file)) > 0) result.append(buffer, read);
  fclose(file);
  return result;
}

void ModuleGen::collect_runtime_functions() {
  std::string runtime = runtime_text();
  size_t position = 0;
  while ((position = runtime.find("(func $", position)) != std::string::npos) {
    position += 6;
    size_t end = runtime.find_first_of(" \n)", position);
    runtime_functions_.insert(runtime.substr(position, end - position));
  }
}

// Note that the class of floats is called "float".
static const char* SPECIAL_CLASSES[] = {
  "String_", "SmallArray_", "ByteArray_", "float", "LargeInteger_", "SmallInteger_", "Null_",
};

void ModuleGen::assign_names() {
  int index = 0;
  auto name_method = [&](ir::Method* method) {
    std::string name = "$m" + std::to_string(index++) + ".";
    if (method->holder() != null) {
      name += method->holder()->name().c_str();
      name += ".";
    }
    name += method->name().is_valid() ? method->name().c_str() : "<anonymous>";
    if (method->is_setter()) name += "=";
    method_names_[method] = sanitize(name.c_str());
  };
  for (auto method : program_->methods()) name_method(method);
  for (auto klass : program_->classes()) {
    for (auto method : klass->methods()) name_method(method);
  }
  for (auto global : program_->globals()) {
    method_names_[global] = sanitize(format("$g%d.%s", global->global_id(), global->name().c_str()).c_str());
  }
}

void ModuleGen::compile_method(ir::Method* method) {
  if (method->is_IsInterfaceOrMixinStub()) return;
  if (method->body() == null) return;
  if (method->is_dead()) return;
  FunctionGen gen(this, null, FunctionGen::METHOD, method, function_name(method));
  add_function(gen.generate());
}

std::string ModuleGen::emit() {
  collect_runtime_functions();

  for (auto klass : program_->classes()) {
    if (!klass->is_runtime_class()) continue;
    const char* name = klass->name().c_str();
    for (auto special : SPECIAL_CLASSES) {
      if (strcmp(name, special) == 0) {
        special_classes_.insert(klass);
        if (klass->total_field_count() != 0) FATAL("special class %s has fields", name);
      }
    }
    if (strcmp(name, "Lambda") == 0) {
      lambda_class_ = klass;
      for (auto field : klass->fields()) {
        if (strcmp(field->name().c_str(), "method_") == 0) lambda_method_field_ = field;
        if (strcmp(field->name().c_str(), "arguments_") == 0) lambda_arguments_field_ = field;
      }
    }
  }

  for (auto global : program_->globals()) {
    auto holder = global->holder();
    if (holder != null && holder->is_runtime_class() &&
        strcmp(holder->name().c_str(), "Task_") == 0 &&
        strcmp(global->name().c_str(), "current") == 0) {
      current_task_global_ = global;
    }
  }
  if (current_task_global_ == null) FATAL("no Task_.current");

  // Analyze all functions.
  ArityCollector arities;
  for (auto method : program_->methods()) arities.visit(method);
  for (auto klass : program_->classes()) {
    for (auto method : klass->methods()) arities.visit(method);
  }
  for (auto global : program_->globals()) arities.visit(global);
  max_block_arity_ = arities.max_block_arity;
  max_lambda_arity_ = arities.max_lambda_arity;
  max_arity_ = std::max(max_arity_, arities.max_call_arity);

  EnvAnalyzer analyzer(&infos_);
  for (auto method : program_->methods()) analyzer.analyze(method);
  for (auto klass : program_->classes()) {
    for (auto method : klass->methods()) analyzer.analyze(method);
  }
  for (auto global : program_->globals()) analyzer.analyze(global);

  assign_names();

  // Class struct types. Special classes use the runtime's types.
  std::set<ir::Class*> supers;
  for (auto klass : program_->classes()) {
    if (klass->super() != null) supers.insert(klass->super());
  }
  std::string class_types;
  for (auto klass : program_->classes()) {
    if (klass->is_interface() || klass->is_mixin()) continue;
    const char* name = klass->name().c_str();
    if (special_classes_.count(klass) != 0) {
      if (strcmp(name, "String_") == 0) class_types_[klass] = "$String";
      if (strcmp(name, "SmallArray_") == 0) class_types_[klass] = "$Array";
      if (strcmp(name, "ByteArray_") == 0) class_types_[klass] = "$ByteArray";
      if (strcmp(name, "float") == 0) class_types_[klass] = "$Float";
      if (strcmp(name, "LargeInteger_") == 0) class_types_[klass] = "$LargeInt";
      continue;
    }
    if (klass->super() == null) {
      // The root class Object has no fields.
      ASSERT(klass->total_field_count() == 0);
      class_types_[klass] = "$Object";
      continue;
    }
    std::string type = sanitize(format("$C%d.%s", klass->id(), name).c_str());
    class_types_[klass] = type;
    std::string super_type = class_type(klass->super());
    if (special_classes_.count(klass->super()) != 0) super_type = "$Object";
    std::string fields = "(field $cid i32)";
    for (int i = 0; i < klass->total_field_count(); i++) fields += " (field (mut eqref))";
    bool is_final = supers.count(klass) == 0;
    class_types += format("    (type %s (sub %s%s (struct %s)))\n",
                          type.c_str(), is_final ? "final " : "", super_type.c_str(), fields.c_str());
  }

  // Compile all functions. This also collects literals, blocks and lambdas.
  for (auto method : program_->methods()) compile_method(method);
  for (auto klass : program_->classes()) {
    for (auto method : klass->methods()) compile_method(method);
  }
  std::vector<std::string> initializers;
  for (auto global : program_->globals()) {
    if (!global->is_lazy()) continue;
    initializers.push_back(function_name(global));
    FunctionGen gen(this, null, FunctionGen::METHOD, global, function_name(global));
    add_function(gen.generate());
  }

  std::string out = "(module\n";

  // Types.
  out += "  (type $Bytes (array (mut i8)))\n";
  out += "  (type $Values (array (mut eqref)))\n";
  out += "  (type $I32s (array i32))\n";
  for (int i = 0; i <= max_arity_; i++) {
    std::string params;
    for (int j = 0; j < i; j++) params += " eqref";
    out += format("  (type $f%d (func (param%s) (result eqref)))\n", i, params.c_str());
  }
  out += "  (rec\n";
  out += "    (type $Object (sub (struct (field $cid i32))))\n";
  out += "    (type $String (sub final $Object (struct (field $cid i32) (field $hash (mut i32)) (field $bytes (ref $Bytes)))))\n";
  out += "    (type $ByteArray (sub final $Object (struct (field $cid i32) (field $bytes (mut (ref $Bytes))))))\n";
  out += "    (type $Array (sub final $Object (struct (field $cid i32) (field $values (ref $Values)))))\n";
  out += "    (type $Float (sub final $Object (struct (field $cid i32) (field $value f64))))\n";
  out += "    (type $LargeInt (sub final $Object (struct (field $cid i32) (field $value i64))))\n";
  out += "    (type $Failure (struct (field eqref)))\n";
  out += "    (type $Env (sub (struct (field $parent (ref null $Env)))))\n";
  for (size_t i = 0; i < env_slot_counts_.size(); i++) {
    std::string fields = "(field $parent (ref null $Env))";
    for (int j = 0; j < env_slot_counts_[i]; j++) fields += " (field (mut eqref))";
    out += format("    (type $E%d (sub final $Env (struct %s)))\n", static_cast<int>(i), fields.c_str());
  }
  std::string block_params;
  for (int i = 0; i < max_block_arity_; i++) block_params += " eqref";
  out += "    (type $Block (struct (field $fn (ref $BlockFn)) (field $env (ref null $Env))))\n";
  out += format("    (type $BlockFn (func (param (ref $Block) i32%s) (result eqref)))\n", block_params.c_str());
  std::string lambda_params;
  for (int i = 0; i < max_lambda_arity_; i++) lambda_params += " eqref";
  out += format("    (type $LambdaFn (func (param eqref i32%s) (result eqref)))\n", lambda_params.c_str());
  out += class_types;
  out += "  )\n";

  // The runtime: first its imports, which must precede all definitions.
  std::string runtime = runtime_text();
  const char* marker = ";; @end-imports";
  size_t split = runtime.find(marker);
  if (split == std::string::npos) FATAL("runtime has no import marker");
  out += runtime.substr(0, split);

  out += "  (tag $throw (param eqref))\n";
  out += "  (tag $nlr (param (ref $Env) eqref))\n";
  out += "  (tag $nlbr (param (ref $Env) i32))\n";

  // Class ids used by the runtime.
  static const char* runtime_classes[] = {
    "String_", "SmallArray_", "ByteArray_", "CowByteArray_", "ByteArraySlice_", "StringSlice_",
    "float_", "LargeInteger_", "SmallInteger_", "Null_", "True", "False", "Task_",
    "LazyInitializer_", "Exception_", "Tombstone_", "List_", "LargeArray_", "Lambda",
    "StringByteSlice_", "Map", "ListSlice_",
  };
  std::map<std::string, ir::Class*> classes_by_name;
  for (auto klass : program_->classes()) {
    if (klass->is_runtime_class()) classes_by_name[klass->name().c_str()] = klass;
  }
  for (auto name : runtime_classes) {
    // The class of floats is called "float", but that is a WebAssembly
    // keyword.
    auto probe = classes_by_name.find(strcmp(name, "float_") == 0 ? "float" : name);
    int id = probe == classes_by_name.end() ? -1 : probe->second->id();
    out += format("  (global $cid.%s i32 (i32.const %d))\n", name, id);
  }
  auto true_class = classes_by_name["True"];
  auto false_class = classes_by_name["False"];
  for (auto klass : { true_class, false_class }) {
    std::string fields;
    for (int i = 0; i < klass->total_field_count(); i++) fields += " (ref.null none)";
    out += format("  (global $%s (ref %s) (struct.new %s (i32.const %d)%s))\n",
                  klass == true_class ? "true" : "false",
                  class_type(klass).c_str(), class_type(klass).c_str(), klass->id(), fields.c_str());
  }
  out += "  (global $globals (mut (ref null $Values)) (ref.null $Values))\n";
  out += format("  (global $gid.Task_.current i32 (i32.const %d))\n", current_task_global_->global_id());
  out += "  (global $literals (mut (ref null $Values)) (ref.null $Values))\n";
  out += "  (global $selectors (mut (ref null $I32s)) (ref.null $I32s))\n";

  // Allocation helpers for the runtime.
  auto emit_allocator = [&](const char* class_name) {
    auto klass = classes_by_name[class_name];
    if (klass == null) {
      out += format("  (func $new.%s (result (ref $Object))\n    unreachable)\n", class_name);
      return;
    }
    std::string type = class_type(klass);
    out += format("  (func $new.%s (result (ref %s))\n    i32.const %d\n", class_name, type.c_str(), klass->id());
    for (int i = 0; i < klass->total_field_count(); i++) out += "    ref.null none\n";
    out += format("    struct.new %s)\n", type.c_str());
  };
  emit_allocator("Task_");
  emit_allocator("Exception_");
  emit_allocator("LazyInitializer_");
  emit_allocator("Map");
  // Field accessors for the runtime.
  auto emit_field_accessors = [&](const char* class_name, const char* field_name, const char* accessor) {
    auto klass = classes_by_name[class_name];
    if (klass == null) {
      out += format("  (func $get.%s (param eqref) (result eqref)\n    unreachable)\n", accessor);
      out += format("  (func $set.%s (param eqref eqref)\n    unreachable)\n", accessor);
      return;
    }
    std::string type = class_type(klass);
    for (auto current = klass; current != null; current = current->super()) {
      for (auto field : current->fields()) {
        if (strcmp(field->name().c_str(), field_name) != 0) continue;
        int index = field->resolved_index() + 1;
        out += format("  (func $get.%s (param eqref) (result eqref)\n"
                      "    local.get 0\n    ref.cast (ref %s)\n    struct.get %s %d)\n",
                      accessor, type.c_str(), type.c_str(), index);
        out += format("  (func $set.%s (param eqref eqref)\n"
                      "    local.get 0\n    ref.cast (ref %s)\n    local.get 1\n    struct.set %s %d)\n",
                      accessor, type.c_str(), type.c_str(), index);
        return;
      }
    }
    FATAL("no field %s in %s", field_name, class_name);
  };
  // The runtime reads the fields of these classes by index, like the VM
  // (see Object::byte_content).
  for (auto class_name : { "CowByteArray_", "ByteArraySlice_", "StringSlice_", "StringByteSlice_" }) {
    auto klass = classes_by_name[class_name];
    for (int i = 0; i < 3; i++) {
      out += format("  (func $field.%s.%d (param eqref) (result eqref)\n", class_name, i);
      if (klass == null || i >= klass->total_field_count()) {
        out += "    unreachable)\n";
      } else {
        std::string type = class_type(klass);
        out += format("    local.get 0\n    ref.cast (ref %s)\n    struct.get %s %d)\n",
                      type.c_str(), type.c_str(), i + 1);
      }
      out += format("  (func $field_set.%s.%d (param eqref eqref)\n", class_name, i);
      if (klass == null || i >= klass->total_field_count()) {
        out += "    unreachable)\n";
      } else {
        std::string type = class_type(klass);
        out += format("    local.get 0\n    ref.cast (ref %s)\n    local.get 1\n    struct.set %s %d)\n",
                      type.c_str(), type.c_str(), i + 1);
      }
    }
  }
  emit_field_accessors("Task_", "id_", "Task_.id");
  emit_field_accessors("List_", "array_", "List_.array");
  emit_field_accessors("List_", "size_", "List_.size");
  emit_field_accessors("Exception_", "value", "Exception_.value");
  emit_field_accessors("Exception_", "trace", "Exception_.trace");
  emit_field_accessors("LazyInitializer_", "id-or-tasks_", "LazyInitializer_.id");
  emit_field_accessors("Map", "size_", "Map.size");
  emit_field_accessors("Map", "index-spaces-left_", "Map.spaces_left");
  emit_field_accessors("Map", "index_", "Map.index");
  emit_field_accessors("Map", "backing_", "Map.backing");
  emit_field_accessors("ListSlice_", "list_", "ListSlice_.list");
  emit_field_accessors("ListSlice_", "from_", "ListSlice_.from");
  emit_field_accessors("ListSlice_", "to_", "ListSlice_.to");

  // Entry points.
  const char* entry_names[] = {
#define E(n, lib_name, a) #n,
ENTRY_POINTS(E)
#undef E
  };
  int entry_arities[] = {
#define E(n, lib_name, a) a,
ENTRY_POINTS(E)
#undef E
  };
  auto entry_points = program_->entry_points();
  for (int i = 0; i < entry_points.length(); i++) {
    int arity = entry_arities[i];
    out += format("  (func $entry.%s (type $f%d)\n", entry_names[i], arity);
    for (int j = 0; j < arity; j++) out += format("    local.get %d\n", j);
    out += format("    return_call %s)\n", function_name(entry_points[i]).c_str());
  }

  // The dispatch table and the selector offset of every slot.
  int length = dispatch_table_->length();
  std::vector<std::string> slots(length);
  std::vector<int32> selectors(length, -1);
  auto add_to_table = [&](ir::Method* method) {
    if (method->is_static()) return;
    if (method->holder() != null && method->holder()->is_mixin()) return;
    Selector<PlainShape> selector(method->name(), method->plain_shape());
    int offset = dispatch_table_->dispatch_offset_for(selector);
    if (offset < 0) return;
    bool is_callable = !method->is_IsInterfaceOrMixinStub() && method->body() != null;
    std::function<void (int)> callback = [&](int index) {
      selectors[index] = offset;
      if (is_callable) slots[index] = function_name(method);
    };
    dispatch_table_->for_each_slot_index(method, offset, callback);
  };
  for (auto klass : program_->classes()) {
    for (auto method : klass->methods()) add_to_table(method);
  }
  out += format("  (table $dispatch %d funcref)\n", length);
  for (int i = 0; i < length; i++) {
    if (slots[i].empty()) continue;
    int end = i;
    std::string names;
    while (end < length && !slots[end].empty()) {
      names += " " + slots[end];
      end++;
    }
    out += format("  (elem (table $dispatch) (i32.const %d) func%s)\n", i, names.c_str());
    i = end - 1;
  }
  std::string selector_bytes;
  for (int32 selector : selectors) {
    for (int i = 0; i < 4; i++) selector_bytes += static_cast<char>((selector >> (8 * i)) & 0xff);
  }
  out += format("  (data $selectors %s)\n",
                wat_string(reinterpret_cast<const uint8*>(selector_bytes.data()),
                           static_cast<int>(selector_bytes.size())).c_str());

  // Lambdas and global initializers are called through tables.
  std::string names;
  for (auto& name : lambda_functions_) names += " " + name;
  out += format("  (table $lambdas %d funcref)\n", static_cast<int>(lambda_functions_.size()));
  if (!lambda_functions_.empty()) out += format("  (elem (table $lambdas) (i32.const 0) func%s)\n", names.c_str());
  names.clear();
  for (auto& name : initializers) names += " " + name;
  out += format("  (table $initializers %d funcref)\n", static_cast<int>(initializers.size()));
  if (!initializers.empty()) out += format("  (elem (table $initializers) (i32.const 0) func%s)\n", names.c_str());
  names.clear();
  for (auto& name : referenced_functions_) names += " " + name;
  if (!referenced_functions_.empty()) out += format("  (elem declare func%s)\n", names.c_str());

  // The initialization creates the literals and the globals. It is
  // generated before the literals are emitted, since it adds literals.
  std::string initialize;
  auto globals = program_->globals();
  initialize += format("    i32.const %d\n    array.new_default $Values\n    global.set $globals\n", globals.length());
  int initializer_index = 0;
  for (auto global : globals) {
    initialize += format("    global.get $globals\n    i32.const %d\n", global->global_id());
    if (global->is_lazy()) {
      initialize += "    call $new.LazyInitializer_\n";
      initialize += format("    local.tee 0\n    i32.const %d\n    ref.i31\n    call $set.LazyInitializer_.id\n    local.get 0\n",
                    initializer_index++);
    } else {
      auto body = global->body();
      if (body->is_Sequence()) body = body->as_Sequence()->expressions()[0];
      auto value = body->as_Return()->value();
      if (value->is_LiteralNull()) {
        initialize += "    ref.null none\n";
      } else if (value->is_LiteralInteger()) {
        int64 v = value->as_LiteralInteger()->value();
        if (-(1LL << 30) <= v && v < (1LL << 30)) {
          initialize += format("    i32.const %d\n    ref.i31\n", static_cast<int>(v));
        } else {
          initialize += format("    global.get %s\n", large_integer_literal(v).c_str());
        }
      } else if (value->is_LiteralString()) {
        auto string = value->as_LiteralString();
        int id = string_literal(string->value(), string->length());
        initialize += format("    global.get $literals\n    i32.const %d\n    array.get $Values\n", id);
      } else if (value->is_LiteralFloat()) {
        initialize += format("    global.get %s\n", float_literal(value->as_LiteralFloat()->value()).c_str());
      } else if (value->is_LiteralBoolean()) {
        initialize += value->as_LiteralBoolean()->value() ? "    global.get $true\n" : "    global.get $false\n";
      } else {
        UNREACHABLE();
      }
    }
    initialize += "    array.set $Values\n";
  }
  initialize += "  )\n";
  // The literals must be created first, but we only know how many there
  // are after the globals have been initialized.
  initialize = format("  (func $initialize\n"
                      "    (local (ref null $Object))\n"
                      "    i32.const %d\n"
                      "    call $create_literals\n"
                      "    i32.const 0\n"
                      "    i32.const %d\n"
                      "    array.new_data $I32s $selectors\n"
                      "    global.set $selectors\n",
                      static_cast<int>(string_literals_.size()), length) + initialize;

  // Literals.
  for (auto& global : constant_globals_) out += "  " + global + "\n";
  out += format("  (data $strings %s)\n",
                wat_string(reinterpret_cast<const uint8*>(string_data_.data()),
                           static_cast<int>(string_data_.size())).c_str());
  std::string literal_table;
  for (auto& literal : string_literals_) {
    for (int value : { literal.first, literal.second }) {
      for (int i = 0; i < 4; i++) literal_table += static_cast<char>((value >> (8 * i)) & 0xff);
    }
  }
  out += format("  (data $literal_table %s)\n",
                wat_string(reinterpret_cast<const uint8*>(literal_table.data()),
                           static_cast<int>(literal_table.size())).c_str());

  // The rest of the runtime and the compiled functions.
  out += runtime.substr(split + strlen(marker));
  out += functions_;
  out += initialize;

  // The embedder creates the main task, so it knows the task when it switches
  // back to it, and then runs the program on it.
  out += "  (func (export \"create_main_task\") (result eqref)\n";
  out += "    (local eqref)\n";
  out += "    call $new.Task_\n";
  out += "    local.tee 0\n";
  out += "    i32.const 0\n";
  out += "    ref.i31\n";
  out += "    call $set.Task_.id\n";
  out += "    local.get 0)\n";
  out += "  (func (export \"main\") (param eqref)\n";
  out += "    call $initialize\n";
  out += "    local.get 0\n";
  out += "    call $entry.entry_main\n";
  out += "    drop)\n";
  out += ")\n";
  return out;
}

}  // namespace

std::string WasmBackend::emit() {
  ModuleGen gen(program_, dispatch_table_);
  return gen.emit();
}

} // namespace toit::compiler
} // namespace toit
