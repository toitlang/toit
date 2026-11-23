// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "process.cc"
#include "process_group.cc"
#include "primitive_policy.cc"
#include "primitive.cc"
#undef private

using namespace toit;
extern VM vm;
extern Scheduler scheduler;
VM* VM::current_ = &vm;
static Process* sender;
static Object* payload;
static Object* size_error_value;
static Object* write_error_value;
static int pid, message_type, boot;
static bool admitted, size_ok, write_ok, buffer_ok, message_ok;
static bool size_hit_quota;
static word bytes, external_bytes;
static unsigned passes, allocations, publications, deliveries, errors, boot_reads;
static message_err_t delivery_result;
static uint8 buffer_identity;

int Scheduler::next_process_id() { return 17; }
int Scheduler::boot_process_id() {
  CXXV_ASSERT(this == &scheduler && sender->policy()->restricts_messaging() && message_type == SYSTEM_TRACE && pid >= 0,
              "look up the boot pid only for restricted direct trace messages");
  ++boot_reads;
  return boot;
}

#include "process_send_constructors.inc"
MessageEncoder::~MessageEncoder() {}

bool MessageEncoder::encode_any(Object* object) {
  CXXV_ASSERT(admitted && object == payload && process_ == sender && format_ == MESSAGE_FORMAT_IPC,
              "both encoding passes receive the authorized sender and original payload");
  bool sizing = passes == 0;
  CXXV_ASSERT(passes < 2 && (sizing ? buffer_ == nullptr : buffer_ == &buffer_identity && allocations == 1),
              "size first and write only into the allocated buffer");
  CXXV_ASSERT(max_total_size_ == (sizing ? sender->policy()->quotas().max_message_bytes : 0),
              "apply the sender's quota during the size pass");
  ++passes;
  cursor_ = bytes;
  external_bytes_ = external_bytes;
  if (sizing && !size_ok && size_hit_quota) over_limit_ = true;
  return sizing ? size_ok : write_ok;
}

Object* MessageEncoder::create_error_object(Process* process) {
  CXXV_ASSERT(process == sender && (passes == 1 || passes == 2), "obtain an encoding error from the failing pass");
  CXXV_ASSERT(buffer_ == (passes == 1 ? nullptr : &buffer_identity), "consult the encoder for the failing pass");
  ++errors;
  return passes == 1 ? size_error_value : write_error_value;
}

static void* allocate_buffer(size_t size) {
  CXXV_ASSERT(passes == 1 && allocations == 0 && size == static_cast<size_t>(bytes),
              "allocate exactly the in-buffer bytes after sizing");
  ++allocations;
  return buffer_ok ? &buffer_identity : nullptr;
}

uint8* MessageEncoder::take_buffer() {
  CXXV_ASSERT(passes == 2 && write_ok && buffer_ == &buffer_identity, "publish only a successfully encoded buffer");
  uint8* result = buffer_;
  buffer_ = nullptr;
  ++publications;
  return result;
}

message_err_t Scheduler::send_message_from(Process* process, int target, SystemMessage* message) {
  const auto& quotas = sender->policy()->quotas();
  CXXV_ASSERT(this == &scheduler && process == sender && target == pid && publications == 1 && deliveries == 0,
              "deliver the published message once to the requested pid");
  CXXV_ASSERT(message->type() == message_type && message->gid() == sender->group()->id() &&
              message->pid() == sender->id() && message->data() == &buffer_identity && message->size() == bytes + external_bytes,
              "deliver the sender identity, message type and total mailbox charge");
  CXXV_ASSERT(message->is_restricted() == sender->policy()->restricts_messaging() &&
              (!message->is_restricted() || (message->restricted_max_count() == quotas.max_mailbox_messages &&
                                             message->restricted_max_bytes() == quotas.max_mailbox_bytes)),
              "propagate both mailbox limits for restricted senders");
  ++deliveries;
  return delivery_result;
}

namespace toit {
// Preserve the native new-expression on success and exercise its null result.
#undef _new
#define _new !message_ok ? nullptr : new
#define malloc allocate_buffer
#include "process_send.inc"
#undef malloc
#undef _new
}

static Object* failure(int index) {
  return reinterpret_cast<Object*>((static_cast<uword>(index) << Error::ERROR_SHIFT) | Error::ERROR_TAG);
}

struct IntArgument {
  Object* object;
  int error;
  int value;
};

static IntArgument argument(uword* header) {
  word value = nondet_word();
  CXXV_ASSUME(Smi::is_valid(value));
  if (nondet_bool()) return {Smi::from(value), value < INT_MIN || value > INT_MAX ? Program::OUT_OF_RANGE_INDEX : -1,
                            static_cast<int>(value)};
  bool boxed = nondet_bool();
  *header = 2 * (boxed ? LARGE_INTEGER_TAG : INSTANCE_TAG);
  return {HeapObject::from_address(reinterpret_cast<uword>(header)), boxed ? Program::OUT_OF_RANGE_INDEX : Program::WRONG_OBJECT_TYPE_INDEX, 0};
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  vm.scheduler_ = &scheduler;
  PrimitivePolicy policy;
  bool restricted = nondet_bool();
  policy.kind_ = restricted ? PrimitivePolicy::UNTRUSTED : PrimitivePolicy::TRUSTED;
  word quota = nondet_word();
  CXXV_ASSUME(quota >= 0);
  policy.quotas_.max_message_bytes = quota;
  policy.quotas_.max_mailbox_messages = nondet_word();
  policy.quotas_.max_mailbox_bytes = nondet_word();
  auto* group = new ProcessGroup(9, nullptr, nullptr, &policy);
  CXXV_ASSUME(group != nullptr);
  sender = new Process(static_cast<ProcessRunner*>(nullptr), group, nullptr);
  CXXV_ASSUME(sender != nullptr);
  uword yes = 0, no = 0, pid_header, type_header;
  sender->true_object_ = HeapObject::from_address(reinterpret_cast<uword>(&yes));
  sender->false_object_ = HeapObject::from_address(reinterpret_cast<uword>(&no));
  auto target = argument(&pid_header);
  auto type = argument(&type_header);
  pid = target.value;
  message_type = type.value;
  boot = nondet_int();
  bool permitted_type = message_type >= MESSAGING_RESERVED_MESSAGE_TYPES || message_type == SYSTEM_TRACE ||
      message_type == SYSTEM_RPC_REQUEST || message_type == SYSTEM_RPC_REPLY || message_type == SYSTEM_RPC_CANCEL ||
      message_type == SYSTEM_RPC_NOTIFY_RESOURCE;
  bool direct_trace = restricted && message_type == SYSTEM_TRACE && pid >= 0;
  int arg_error = target.error >= 0 ? target.error : type.error;
  admitted = arg_error < 0 && (!restricted || permitted_type) && (!direct_trace || pid == boot);
  bytes = nondet_word();
  external_bytes = nondet_word();
  CXXV_ASSUME(bytes >= 0 && external_bytes >= 0 && external_bytes <= INTPTR_MAX - bytes);
  word total = bytes + external_bytes;
  bool exceeds_quota = quota > 0 && total > quota;
  size_hit_quota = exceeds_quota && nondet_bool();
  size_ok = nondet_bool();
  write_ok = nondet_bool();
  buffer_ok = nondet_bool();
  message_ok = nondet_bool();
  int status = nondet_int();
  CXXV_ASSUME(status >= MESSAGE_OK && status <= MESSAGE_QUOTA_EXCEEDED);
  delivery_result = static_cast<message_err_t>(status);
  // Error creation can also return an allocated error. Forward its bits unchanged.
  size_error_value = reinterpret_cast<Object*>(nondet_ulong() | Error::ERROR_TAG);
  write_error_value = reinterpret_cast<Object*>(nondet_ulong() | Error::ERROR_TAG);
  payload = reinterpret_cast<Object*>(nondet_ulong());
  Object* args[] = {payload, type.object, target.object};
  Object* result = primitive_process_send(sender, args + 2);
  CXXV_ASSERT(args[0] == payload && args[1] == type.object && args[2] == target.object, "preserve all caller argument slots");
  bool over = size_ok ? exceeds_quota : size_hit_quota;
  bool size_error = !size_ok || total > MESSAGING_ENCODING_MAX_SIZE;
  bool allocate = admitted && !size_error && !over;
  bool write = allocate && buffer_ok;
  bool send = write && write_ok && message_ok;
  Object* expected;
  if (arg_error >= 0) expected = failure(arg_error);
  else if (!admitted) expected = failure(Program::PERMISSION_DENIED_INDEX);
  else if (over) expected = failure(Program::QUOTA_EXCEEDED_INDEX);
  else if (size_error) expected = size_error_value;
  else if (!buffer_ok) expected = failure(Program::MALLOC_FAILED_INDEX);
  else if (!write_ok) expected = write_error_value;
  else if (!message_ok) expected = failure(Program::MALLOC_FAILED_INDEX);
  else if (status == MESSAGE_PERMISSION_DENIED) expected = failure(Program::PERMISSION_DENIED_INDEX);
  else if (restricted && status == MESSAGE_QUOTA_EXCEEDED) expected = failure(Program::QUOTA_EXCEEDED_INDEX);
  else expected = status == MESSAGE_OK ? sender->true_object() : sender->false_object();
  CXXV_ASSERT(reinterpret_cast<uword>(result) == reinterpret_cast<uword>(expected), "return the exact value or tagged error");
  CXXV_ASSERT(passes == static_cast<unsigned>(admitted) + write && allocations == allocate &&
              publications == send && deliveries == send, "execute exactly the permitted stages");
  CXXV_ASSERT(boot_reads == (arg_error < 0 && direct_trace) &&
              errors == ((admitted && size_error && !over) || (write && !write_ok)), "perform only required identity and error lookups");
}
