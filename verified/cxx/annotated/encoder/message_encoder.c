// Copyright (C) 2026 Toit contributors.
//
// MessageEncoder::encode_any, encode_array, encode_list and encode_map of
// src/messaging.cc, rendered in C over the object model of
// ../model/objects.h, with VeriFast annotations.
//
// Property: for any heap that satisfies the object model (every reference
// is a live object of the right layout; field VALUES arbitrary: sizes,
// bounds, backings are whatever a program stored), the encoder reads only
// inside objects (memory safety), has no signed overflow, and does not
// change the heap (it holds only a fraction of it, given back unchanged).
// Unbounded: any heap, any sizes, any nesting.
//
// With -DF708AD5D_REVERTED the three bounds checks of commit f708ad5d are
// taken out again (encode_array, encode_list, encode_map as before it);
// VeriFast must then fail at the out-of-bounds read.

#include "../model/objects.h"

#define TAG_POSITIVE_SMI 0
#define TAG_NEGATIVE_SMI 1
#define TAG_NULL 2
#define TAG_TRUE 3
#define TAG_FALSE 4
#define TAG_ARRAY 5
#define TAG_MAP 7
#define TAG_DOUBLE 8
#define TAG_LARGE_INTEGER 9
#define TAG_BYTE_ARRAY 10
#define TAG_STRING 11
#define MESSAGING_ENCODING_MAX_NESTING 8

// With F708AD5D_REVERTED, encode_array has only `ASSERT(from <= to)`,
// which release builds drop. -DASSUME_FROM_LE_TO assumes 0 <= from <= to
// there instead (a call of a function whose contract says so), to get past
// the first bugs (a negative count, a negative index) to the read past the
// end of the array. (A ghost `assume` inside a skipped #ifdef region
// confuses VeriFast's preprocessor, hence the function.)
#ifdef ASSUME_FROM_LE_TO
void assume_slice_range(word from, word to);
//@ requires true;
//@ ensures 0 <= from &*& from <= to;
#define ASSUME_SLICE_RANGE(from, to) assume_slice_range(from, to)
#else
#define ASSUME_SLICE_RANGE(from, to)
#endif

/*@
fixpoint bool smi_range(int v) { return -(UINTPTR_MAX / 4) - 1 <= v && v <= UINTPTR_MAX / 4; }
@*/

// The map loop's condition: `count < size && i + 1 < limit` since f708ad5d,
// `count < size` before.
#ifndef F708AD5D_REVERTED
#define MAP_LOOP_LIMIT(i, limit) (i + 1 < limit)
#else
#define MAP_LOOP_LIMIT(i, limit) true
#endif

// ---------------------------------------------------------------------------
// The program's roots (src/program.h): trusted accessors.

struct Program;
typedef struct Program Program;

//@ predicate program(Program *p; prog_ids ids);

Smi *Program_array_class_id(Program *p);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids) &*& result == smi_ptr(array_cid(ids));
Smi *Program_list_class_id(Program *p);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids) &*& result == smi_ptr(list_cid(ids));
Smi *Program_list_slice_class_id(Program *p);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids) &*& result == smi_ptr(list_slice_cid(ids));
Smi *Program_map_class_id(Program *p);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids) &*& result == smi_ptr(map_cid(ids));
Smi *Program_large_array_class_id(Program *p);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids) &*& result == smi_ptr(large_array_cid(ids));
Smi *Program_tombstone_class_id(Program *p);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids) &*& result == smi_ptr(tombstone_cid(ids));
// The other classes the encoder tests for (byte-array COW, slices, string
// slices): their ids, any values.
Smi *Program_other_class_id(Program *p, int which);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids);
// null_object, true_object, false_object: only compared, never read.
Object *Program_root(Program *p, int which);
//@ requires [?f]program(p, ?ids);
//@ ensures [f]program(p, ids);

// ---------------------------------------------------------------------------
// The encoder's state. Only the fields encode_any uses; the output buffer
// and its counters are the abstract `encoder_buffer`.

struct MessageEncoder {
  Program *program_;
  int nesting_;
  bool nesting_too_deep_;
  word problematic_class_id_;
};
typedef struct MessageEncoder MessageEncoder;

/*@
predicate encoder_buffer(MessageEncoder *e;);

predicate encoder(MessageEncoder *e; prog_ids ids, int nesting) =
  e->program_ |-> ?p &*& [_]program(p, ids) &*& prog_ok(ids) == true &*&
  e->nesting_ |-> nesting &*& 0 <= nesting &*& nesting <= MESSAGING_ENCODING_MAX_NESTING + 1 &*&
  e->nesting_too_deep_ |-> _ &*& e->problematic_class_id_ |-> _ &*&
  encoder_buffer(e);
@*/

// The writers of src/messaging.h (bounds-checked buffer code, not in scope).
void MessageEncoder_write_uint8(MessageEncoder *self, uint8 value);
//@ requires encoder_buffer(self);
//@ ensures encoder_buffer(self);
void MessageEncoder_write_cardinal(MessageEncoder *self, uword value);
//@ requires encoder_buffer(self);
//@ ensures encoder_buffer(self);
bool MessageEncoder_is_too_large(MessageEncoder *self);
//@ requires encoder_buffer(self);
//@ ensures encoder_buffer(self);
bool MessageEncoder_encoding_tison(MessageEncoder *self);
//@ requires encoder_buffer(self);
//@ ensures encoder_buffer(self);

// The leaves that copy blobs or read number objects (encode_copy,
// encode_byte_array, Double::value, LargeInteger::value): assumed to read
// only the given object, with the tag the caller checked.
bool MessageEncoder_encode_copy(MessageEncoder *self, Object *object, int tag);
//@ requires encoder(self, ?ids, ?n) &*& [?f]heap(?objs, ?H) &*& mem(object, objs) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
bool MessageEncoder_encode_byte_array(MessageEncoder *self, ByteArray *object);
//@ requires encoder(self, ?ids, ?n) &*& [?f]heap(?objs, ?H) &*& has_tag(H, object, BYTE_ARRAY_TAG) == true &*& mem(object, objs) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
void MessageEncoder_write_number_object(MessageEncoder *self, Object *object, int tag);
//@ requires encoder(self, ?ids, ?n) &*& [?f]heap(?objs, ?H) &*& has_tag(H, object, tag) == true &*& mem(object, objs) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);

/*@
lemma void encoder_facts(MessageEncoder *e)
  requires encoder(e, ?ids, ?n);
  ensures encoder(e, ids, n) &*& prog_ok(ids) == true;
{
  open encoder(e, ids, n);
  close encoder(e, ids, n);
}

// Shorthand for the facts of an opened object (the instance case).
lemma void instance_facts(list<void *> objs, fixpoint(void *, oinfo) H, void *o, prog_ids ids, int cid)
  requires obj_facts(objs, H, o) == true &*& header_cid(o_hw(H(o))) == cid &*& prog_ok(ids) == true &*&
           header_tag2(o_hw(H(o))) == 2 * INSTANCE_TAG;
  ensures class_tag(cid) == INSTANCE_TAG &*& o_len(H(o)) == class_fields(cid) &*&
          forall(o_words(H(o)), (good)(objs)) == true;
{
}
@*/

bool MessageEncoder_encode_any(MessageEncoder *self, Object *object);
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& good(objs, object) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);

bool MessageEncoder_encode_array(MessageEncoder *self, Array *object, word from, word to);
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(object, objs) == true &*& has_tag(H, object, ARRAY_TAG) == true &*& smi_range(from) == true &*& smi_range(to) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);

bool MessageEncoder_encode_list(MessageEncoder *self, Instance *instance, word from, word to);
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(instance, objs) == true &*& has_tag(H, instance, INSTANCE_TAG) == true &*& header_cid(o_hw(H(instance))) == list_cid(ids) &*& smi_range(from) == true &*& smi_range(to) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);

bool MessageEncoder_encode_map(MessageEncoder *self, Instance *instance);
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(instance, objs) == true &*& has_tag(H, instance, INSTANCE_TAG) == true &*& header_cid(o_hw(H(instance))) == map_cid(ids);
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);

// bool MessageEncoder::encode_any(Object* object) {
//   NestingTracker tracking(&nesting_);   // ++ now, -- on every return
//   ...
// The body below is encode_any after the NestingTracker line; the
// tracker's constructor and destructor are the increment and decrement
// around the call.
static bool encode_any_body(MessageEncoder *self, Object *object)
//@ requires encoder(self, ?ids, ?n) &*& 1 <= n &*& [?f]heap(?objs, ?H) &*& good(objs, object) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
{
  if (self->nesting_ > MESSAGING_ENCODING_MAX_NESTING) {
    self->nesting_too_deep_ = true;
    return false;
  }
  if (MessageEncoder_is_too_large(self)) return false;

  if (is_smi(object)) {
    word value = Smi_value(object);
    if (value >= 0) {
      MessageEncoder_write_uint8(self, TAG_POSITIVE_SMI);
      MessageEncoder_write_cardinal(self, (uword)value);   // C++: implicit word -> uword
    } else {
      MessageEncoder_write_uint8(self, TAG_NEGATIVE_SMI);
      MessageEncoder_write_cardinal(self, (uword)-value);  // C++: implicit word -> uword
    }
    return true;
  }
  //@ good_mem(objs, object);

  Program *program = self->program_;
  if (is_instance(object)) {
    Instance *instance = object;  // Instance::cast(object)
    //@ heap_open(instance);
    Smi *class_id = HeapObject_class_id(instance);
    //@ int cid = header_cid(o_hw(H(instance)));
    //@ instance_facts(objs, H, instance, ids, cid);
    if (class_id == Program_list_class_id(program)) {
      //@ assert prog_ok(ids) == true;
      //@ assert cid == list_cid(ids);
      //@ open body(instance, _, _, _);
      Object *size = Instance_at(instance, LIST_SIZE_INDEX);
      //@ close [f]body(instance, 2 * INSTANCE_TAG, o_len(H(instance)), o_words(H(instance)));
      //@ heap_close(instance);
      if (!is_smi(size)) return false;
      return MessageEncoder_encode_list(self, instance, 0, Smi_value(size));
    } else if (class_id == Program_list_slice_class_id(program)) {
      //@ open body(instance, _, _, _);
      Object *from_object = Instance_at(instance, LIST_SLICE_FROM_INDEX);
      Object *to_object = Instance_at(instance, LIST_SLICE_TO_INDEX);
      Object *backing_object = Instance_at(instance, LIST_SLICE_LIST_INDEX);
      //@ good_nth(objs, o_words(H(instance)), LIST_SLICE_LIST_INDEX);
      //@ close [f]body(instance, 2 * INSTANCE_TAG, o_len(H(instance)), o_words(H(instance)));
      //@ heap_close(instance);
      if (!is_smi(from_object) || !is_smi(to_object)) return false;
      word from = Smi_value(from_object);
      word to = Smi_value(to_object);
      // (C++ reads the backing field here; the rendering reads it above,
      // with the other fields, while the instance is open.)
      if (is_array(backing_object)) {
        Array *backing = backing_object;
        //@ good_heap(objs, backing);
        return MessageEncoder_encode_array(self, backing, from, to);
      } else if (is_instance(backing_object)) {
        Instance *backing = backing_object;
        //@ good_heap(objs, backing);
        //@ heap_open(backing);
        Smi *backing_class_id = HeapObject_class_id(backing);
        //@ heap_close(backing);
        if (backing_class_id != Program_list_class_id(program)) {
          self->problematic_class_id_ = Smi_value(backing_class_id);
          return false;
        }
        return MessageEncoder_encode_list(self, backing, from, to);
      } else {
        return false;
      }
    } else if (class_id == Program_map_class_id(program)) {
      //@ heap_close(instance);
      return MessageEncoder_encode_map(self, instance);
    } else {
      // byte_array_cow, byte_array_slice, string_byte_slice, string_slice:
      // encode_copy; any other class: problematic_class_id_.
      //@ heap_close(instance);
      Smi *other = Program_other_class_id(program, 0);
      if (class_id == other) return MessageEncoder_encode_copy(self, object, TAG_BYTE_ARRAY);
      self->problematic_class_id_ = Smi_value(class_id);
    }
  } else if (object == Program_root(program, 0)) {
    MessageEncoder_write_uint8(self, TAG_NULL);
    return true;
  } else if (object == Program_root(program, 1)) {
    MessageEncoder_write_uint8(self, TAG_TRUE);
    return true;
  } else if (object == Program_root(program, 2)) {
    MessageEncoder_write_uint8(self, TAG_FALSE);
    return true;
  } else if (is_byte_array(object)) {
    return MessageEncoder_encode_byte_array(self, object);
  } else if (is_double(object)) {
    MessageEncoder_write_uint8(self, TAG_DOUBLE);
    MessageEncoder_write_number_object(self, object, DOUBLE_TAG);
    return true;
  } else if (is_string(object)) {
    return MessageEncoder_encode_copy(self, object, TAG_STRING);
  } else if (is_array(object)) {
    Array *array = object;
    //@ heap_open(array);
    //@ open body(array, _, _, _);
    word length = Array_length(array);
    //@ array_body_facts(array);
    //@ close [f]body(array, 2 * ARRAY_TAG, o_len(H(array)), o_words(H(array)));
    //@ heap_close(array);
    return MessageEncoder_encode_array(self, array, 0, length);
  } else if (is_large_integer(object)) {
    MessageEncoder_write_uint8(self, TAG_LARGE_INTEGER);
    MessageEncoder_write_number_object(self, object, LARGE_INTEGER_TAG);
    return true;
  }
  return false;
}

bool MessageEncoder_encode_any(MessageEncoder *self, Object *object)
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& good(objs, object) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
{
  self->nesting_++;                                // NestingTracker()
  bool result = encode_any_body(self, object);
  self->nesting_--;                                // ~NestingTracker()
  return result;
}

// bool MessageEncoder::encode_array(Array* object, word from, word to) {
bool MessageEncoder_encode_array(MessageEncoder *self, Array *object, word from, word to)
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(object, objs) == true &*& has_tag(H, object, ARRAY_TAG) == true &*& smi_range(from) == true &*& smi_range(to) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
{
  //@ heap_open(object);
  //@ open body(object, _, _, _);
#ifndef F708AD5D_REVERTED
  // The range comes from the fields of lists and list slices, which Toit
  // code can set to anything.
  if (from < 0 || from > to || to > Array_length(object)) {
    //@ close [f]body(object, 2 * ARRAY_TAG, o_len(H(object)), o_words(H(object)));
    //@ heap_close(object);
    return false;
  }
#else
  // ASSERT(from <= to);  (debug builds only)
#endif
  ASSUME_SLICE_RANGE(from, to);
  //@ close [f]body(object, 2 * ARRAY_TAG, o_len(H(object)), o_words(H(object)));
  //@ heap_close(object);
  MessageEncoder_write_uint8(self, TAG_ARRAY);
  MessageEncoder_write_cardinal(self, (uword)(to - from));   // C++: implicit word -> uword
  for (word i = from; i < to; i++)
  //@ invariant encoder(self, ids, n) &*& [f]heap(objs, H) &*& from <= i;
  {
    //@ heap_open(object);
    //@ open body(object, _, _, _);
    Object *element = Array_at(object, i);
    //@ good_nth(objs, o_words(H(object)), i);
    //@ close [f]body(object, 2 * ARRAY_TAG, o_len(H(object)), o_words(H(object)));
    //@ heap_close(object);
    if (!MessageEncoder_encode_any(self, element)) return false;
  }
  return true;
}

// bool MessageEncoder::encode_list(Instance* instance, word from, word to) {
bool MessageEncoder_encode_list(MessageEncoder *self, Instance *instance, word from, word to)
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(instance, objs) == true &*& has_tag(H, instance, INSTANCE_TAG) == true &*& header_cid(o_hw(H(instance))) == list_cid(ids) &*& smi_range(from) == true &*& smi_range(to) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
{
  //@ heap_open(instance);
  //@ encoder_facts(self);
  //@ instance_facts(objs, H, instance, ids, list_cid(ids));
  //@ open body(instance, _, _, _);
#ifndef F708AD5D_REVERTED
  // Only encode elements that are in the list. The size field is an ordinary
  // instance field and not necessarily within the backing array: encode_array
  // checks that.
  Object *size = Instance_at(instance, LIST_SIZE_INDEX);
#endif
  Object *backing = Instance_at(instance, LIST_ARRAY_INDEX);
  //@ good_nth(objs, o_words(H(instance)), LIST_ARRAY_INDEX);
  //@ close [f]body(instance, 2 * INSTANCE_TAG, o_len(H(instance)), o_words(H(instance)));
  //@ heap_close(instance);
#ifndef F708AD5D_REVERTED
  if (!is_smi(size) || to > Smi_value(size)) return false;
#endif
  if (is_smi(backing)) return false;
  //@ good_mem(objs, backing);
  //@ heap_open(backing);
  Smi *class_id = HeapObject_class_id(backing);
  //@ heap_close(backing);
  if (class_id == Program_array_class_id(self->program_)) {
    Array *array = backing;  // Array::cast(backing)
    return MessageEncoder_encode_array(self, array, from, to);
  } else if (class_id == Program_large_array_class_id(self->program_)) {
    // printf("[message encoder: cannot encode large array]\n") unless TISON.
  }
  return false;
}

// bool MessageEncoder::encode_map(Instance* instance) {
bool MessageEncoder_encode_map(MessageEncoder *self, Instance *instance)
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(instance, objs) == true &*& has_tag(H, instance, INSTANCE_TAG) == true &*& header_cid(o_hw(H(instance))) == map_cid(ids);
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
{
  MessageEncoder_write_uint8(self, TAG_MAP);

  //@ heap_open(instance);
  //@ encoder_facts(self);
  //@ instance_facts(objs, H, instance, ids, map_cid(ids));
  //@ open body(instance, _, _, _);
  Object *object = Instance_at(instance, MAP_BACKING_INDEX);
  //@ good_nth(objs, o_words(H(instance)), MAP_BACKING_INDEX);
  Object *size_object = Instance_at(instance, MAP_SIZE_INDEX);  // (C++ reads it below)
  //@ close [f]body(instance, 2 * INSTANCE_TAG, o_len(H(instance)), o_words(H(instance)));
  //@ heap_close(instance);
  if (is_smi(object)) return false;
  HeapObject *backing = object;
  //@ good_mem(objs, backing);

  object = size_object;
  if (!is_smi(object)) return false;
  word size = Smi_value(object);
#ifndef F708AD5D_REVERTED
  if (size < 0) return false;
#endif

  MessageEncoder_write_cardinal(self, (uword)size);
  if (size == 0) return true;  // Do this before looking at the backing, which may be null.
  word limit = -1;
  //@ heap_open(backing);
  Smi *class_id = HeapObject_class_id(backing);
  //@ heap_close(backing);
  if (class_id == Program_list_class_id(self->program_)) {
    Instance *list = backing;
    //@ heap_open(list);
    //@ instance_facts(objs, H, list, ids, list_cid(ids));
    //@ open body(list, _, _, _);
    Object *list_size = Instance_at(list, LIST_SIZE_INDEX);
    Object *list_array = Instance_at(list, LIST_ARRAY_INDEX);
    //@ good_nth(objs, o_words(H(list)), LIST_ARRAY_INDEX);
    //@ close [f]body(list, 2 * INSTANCE_TAG, o_len(H(list)), o_words(H(list)));
    //@ heap_close(list);
#ifndef F708AD5D_REVERTED
    object = list_size;
    if (!is_smi(object)) return false;
    limit = Smi_value(object);
    if (limit < 0) return false;
#endif
    object = list_array;
    if (is_smi(object)) return false;
    backing = object;
    //@ good_mem(objs, backing);
  }
  //@ heap_open(backing);
  class_id = HeapObject_class_id(backing);
  //@ int bcid = header_cid(o_hw(H(backing)));
  if (class_id != Program_array_class_id(self->program_)) {
    //@ heap_close(backing);
    return false;
  }
  Array *array = backing;
  //@ open body(array, _, _, _);
  //@ array_body_facts(array);
#ifndef F708AD5D_REVERTED
  if (limit < 0) {
    limit = Array_length(array);
  } else if (limit > Array_length(array)) {
    //@ close [f]body(array, 2 * ARRAY_TAG, o_len(H(array)), o_words(H(array)));
    //@ heap_close(array);
    return false;
  }
#endif
  //@ close [f]body(array, 2 * ARRAY_TAG, o_len(H(array)), o_words(H(array)));
  //@ heap_close(array);
  word count = 0;
  for (word i = 0; count < size && MAP_LOOP_LIMIT(i, limit); i += 2)
  //@ invariant encoder(self, ids, n) &*& [f]heap(objs, H) &*& 0 <= i &*& i <= o_len(H(array)) + 1 &*& 0 <= count &*& count <= size &*& limit <= o_len(H(array));
  {
    //@ heap_open(array);
    //@ open body(array, _, _, _);
    Object *key = Array_at(array, i);
    Object *value = Array_at(array, i + 1);
    //@ good_nth(objs, o_words(H(array)), i);
    //@ good_nth(objs, o_words(H(array)), i + 1);
    //@ close [f]body(array, 2 * ARRAY_TAG, o_len(H(array)), o_words(H(array)));
    //@ heap_close(array);
    bool is_tombstone = false;
    if (!is_smi(key)) {
      //@ good_mem(objs, key);
      //@ heap_open(key);
      is_tombstone = HeapObject_class_id(key) == Program_tombstone_class_id(self->program_);
      //@ heap_close(key);
    }
    // if (is_smi(key) || HeapObject::cast(key)->class_id() != program_->tombstone_class_id()) {
    if (!is_tombstone) {
      if (!MessageEncoder_encode_any(self, key)) return false;
      if (!MessageEncoder_encode_any(self, value)) return false;
      count++;
    }
  }
#ifndef F708AD5D_REVERTED
  // The map has fewer entries than its size field claims.
  return count == size;
#else
  return true;
#endif
}
