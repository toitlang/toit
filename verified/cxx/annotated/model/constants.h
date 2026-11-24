// Copyright (C) 2026 Toit contributors.
//
// The constant table of the C renderings (verified/tools/cxx_render.toit).
// Every C++ constant a rendered function uses is here, under the name the
// rendering gives it (`C::N` is `C_N`; an unqualified `N` used inside class
// C is `C_N` if that is here, else `N`). The values are C expressions that
// are also valid C++ inside namespace toit: the translator writes, for
// every place of use, a static_assert that the C++ constant, looked up
// where the code uses it, has this value and type (*.gen.constants.cc),
// and run.sh compiles those for a 64-bit and a 32-bit target. So a value
// here cannot disagree with the headers.

#ifndef TOIT_VF_CONSTANTS_H
#define TOIT_VF_CONSTANTS_H

// src/top.h.
#define WORD_SIZE ((int)sizeof(word))
#define BYTE_BIT_SIZE 8
#define GcMetadata_NEW_SPACE_POINTERS ((uint8)1)
#define CANNOT_RESIZE 1
#define OLD_SPACE_PAGE 1
#define NEW_SPACE_PAGE 2
#define UNKNOWN_SPACE_PAGE 0
#define GcMetadata_NO_NEW_SPACE_POINTERS ((uint8)0)
#define GcMetadata_NO_OBJECT_START 2
#define GcMetadata_MARK_BITS_SHIFT ((int)(sizeof(word) == 8 ? 6 : 5))
#define GcMetadata_CARD_SIZE_IN_BITS_LOG_2 ((int)(sizeof(word) == 8 ? 11 : 10))
#define GcMetadata_CARD_SIZE_LOG_2 ((int)(sizeof(word) == 8 ? 8 : 7))
#define GcMetadata_CARD_SIZE ((int)(32 * sizeof(word)))
#define Scheduler_NUMBER_OF_READY_QUEUES 5
#define Process_PREEMPT 2
#define Process_SUSPENDED_AWAITING_GC 6
#define MarkingStack_CHUNK_SIZE 128
#define FreeList_NUMBER_OF_BUCKETS 12
#define FreeListRegion_NEXT_OFFSET ((word)(2 * sizeof(word)))
#define PromotedTrack_NEXT_OFFSET ((word)(2 * sizeof(word)))
#define PromotedTrack_END_OFFSET ((word)sizeof(word))
#define PromotedTrack_HEADER_SIZE ((word)(3 * sizeof(word)))
#define SENTINEL_SIZE ((uword)sizeof(void *))

// class Object.
#define SMI_TAG_SIZE 1
#define Object_SMI_TAG_MASK ((uword)1)
#define Object_SMI_TAG ((uword)0)
#define Object_MARKED_TAG ((uword)3)
#define Object_NON_SMI_TAG_SIZE 2
#define Object_NON_SMI_TAG_MASK ((uword)3)
#define Object_HEAP_TAG ((uword)1)
#define HEAP_TAG ((uword)1)

// class HeapObject.
#define HeapObject_SIZE ((word)sizeof(word))
#define HEADER_OFFSET ((word)0)
#define HeapObject_CLASS_ID_OFFSET ((word)5)
#define HeapObject_CLASS_ID_MASK ((uword)UINTPTR_MAX)
#define HeapObject_FINALIZER_BIT_OFFSET ((word)4)
#define HeapObject_CLASS_TAG_OFFSET ((word)0)
#define HeapObject_CLASS_TAG_MASK ((uword)15)

#define LargeInteger_VALUE_OFFSET ((word)sizeof(word))

// class Instance, class Array.
#define Array_ARRAYLET_SIZE ((word)500)
#define Instance_HEADER_SIZE ((word)sizeof(word))
#define Task_STACK_INDEX ((word)0)
#define Instance_LIST_ARRAY_INDEX ((word)0)
#define Instance_LIST_SIZE_INDEX ((word)1)
#define Instance_LIST_SLICE_LIST_INDEX ((word)0)
#define Instance_LIST_SLICE_FROM_INDEX ((word)1)
#define Instance_LIST_SLICE_TO_INDEX ((word)2)
#define Instance_MAP_SIZE_INDEX ((word)0)
#define Instance_MAP_BACKING_INDEX ((word)3)
#define Instance_BYTE_ARRAY_COW_BACKING_INDEX ((word)0)
#define Instance_BYTE_ARRAY_COW_IS_MUTABLE_INDEX ((word)1)
#define Instance_BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX ((word)0)
#define Instance_BYTE_ARRAY_SLICE_FROM_INDEX ((word)1)
#define Instance_BYTE_ARRAY_SLICE_TO_INDEX ((word)2)
#define Instance_STRING_SLICE_STRING_INDEX ((word)0)
#define Instance_STRING_SLICE_FROM_INDEX ((word)1)
#define Instance_STRING_SLICE_TO_INDEX ((word)2)
#define Instance_STRING_BYTE_SLICE_STRING_INDEX ((word)0)
#define Instance_STRING_BYTE_SLICE_FROM_INDEX ((word)1)
#define Instance_STRING_BYTE_SLICE_TO_INDEX ((word)2)
#define Stack_HEADER_SIZE ((word)(10 * sizeof(word)))
#define Stack_LENGTH_OFFSET ((word)(2 * sizeof(word)))
#define Stack_PENDING_STACK_CHECK_METHOD_OFFSET ((word)(5 * sizeof(word)))
#define Stack_TRY_TOP_OFFSET ((word)(4 * sizeof(word)))
#define Stack_V2_MAX_LENGTH ((word)65536)
#define Stack_V2_FRAME_TOP_SHIFT 16
#define Stack_V2_FIN_WORDS ((word)5)
#define Stack_TOP_OFFSET ((word)(3 * sizeof(word)))
#define Array_LENGTH_OFFSET ((word)sizeof(word))
#define Array_HEADER_SIZE ((word)(2 * sizeof(word)))

// class String (src/objects.h): [header][hash:h][length:h][content] or
// [header][hash:h][SENTINEL:h][length][address].
#define HALF_WORD_SIZE ((int)(sizeof(word) / 2))
#define String_SENTINEL ((word)65535)
#define String_HASH_CODE_OFFSET ((word)sizeof(word))
#define String_INTERNAL_LENGTH_OFFSET ((word)(sizeof(word) + sizeof(word) / 2))
#define String_INTERNAL_HEADER_SIZE ((word)(2 * sizeof(word)))
#define String_EXTERNAL_LENGTH_OFFSET ((word)(2 * sizeof(word)))
#define String_EXTERNAL_ADDRESS_OFFSET ((word)(3 * sizeof(word)))

// class ByteArray: [header][raw length][content] or [header][-1 - length]
// [address][tag].
#define ByteArray_LENGTH_OFFSET ((word)sizeof(word))
#define ByteArray_HEADER_SIZE ((word)(2 * sizeof(word)))
#define ByteArray_EXTERNAL_ADDRESS_OFFSET ((word)(2 * sizeof(word)))
#define ByteArray_EXTERNAL_TAG_OFFSET ((word)(3 * sizeof(word)))

// enum StructTag (src/tags.h).
#define RawByteTag 0
#define NullStructTag 1

// class Object (byte_content), enum BlobKind.
#define Object_MAX_BYTE_CONTENT_DEPTH 8
#define STRINGS_ONLY 1

// The layout facts of the model's predicates (verified/LAYOUT.toml, shared
// with the Verus heap model: checked against layout.rs and the C++).
#define LAYOUT_HEADER_WORD 0
#define LAYOUT_INSTANCE_FIELDS_WORD 1
#define LAYOUT_ARRAY_LENGTH_WORD 1
#define LAYOUT_ARRAY_ELEMENTS_WORD 2
#define LAYOUT_BYTE_ARRAY_LENGTH_WORD 1
#define LAYOUT_BYTE_ARRAY_CONTENT_BYTE (2 * WORD_SIZE)
#define LAYOUT_BYTE_ARRAY_EXTERNAL_ADDRESS_WORD 2
#define LAYOUT_BYTE_ARRAY_EXTERNAL_TAG_WORD 3
#define LAYOUT_STRING_HASH_CODE_BYTE WORD_SIZE
#define LAYOUT_STRING_INTERNAL_LENGTH_BYTE (WORD_SIZE + HALF_WORD_SIZE)
#define LAYOUT_STRING_CONTENT_BYTE (2 * WORD_SIZE)
#define LAYOUT_STRING_EXTERNAL_LENGTH_WORD 2
#define LAYOUT_STRING_EXTERNAL_ADDRESS_WORD 3

// enum TypeTag.
#define ARRAY_TAG 0
#define STRING_TAG 1
#define INSTANCE_TAG 2
#define ODDBALL_TAG 3
#define DOUBLE_TAG 4
#define BYTE_ARRAY_TAG 5
#define LARGE_INTEGER_TAG 6
#define STACK_TAG 7
#define TASK_TAG 8
#define FREE_LIST_REGION_TAG 9

// src/interpreter_v2.h (the FFI result codes).
#define TOIT_V2_OK ((uword)0)
#define TOIT_V2_STACK_OVERFLOW ((uword)1)
#define TOIT_V2_OUT_OF_MEMORY ((uword)2)
#define TOIT_V2_PRIMITIVE_SUCCESS ((uword)0)
#define TOIT_V2_PRIMITIVE_FAILURE ((uword)1)
#define TOIT_V2_PRIMITIVE_THROW ((uword)2)
#define TOIT_V2_PRIMITIVE_ABSENT ((uword)3)
// src/interpreter_v2.cc: the longest blob the core's allocation makes, the
// model's MAX_BLOB.
#define V2_MAX_BLOB_LENGTH ((uword)(UINTPTR_MAX / 4))
// src/flags.h: a debug flag, a constant in release builds (TOIT_DEPLOY,
// the build the renderings are made for).
#define Flags_primitives false

// src/primitive.h, the error roots of src/program.h, class Error.
#define STRINGS_OR_BYTE_ARRAYS 0
#define FLASH_PAGE_SIZE_LOG2 12
#define Program_ROOT_COUNT 35
#define Program_BUILTIN_CLASS_IDS_COUNT 23
#define Error_MAX_TAGGED_ERROR 256
#define Program_ALLOCATION_FAILED_INDEX 7
#define Program_FIRST_ERROR_INDEX 7
#define Program_PERMISSION_DENIED_INDEX 25
#define Program_ERROR_INDEX 12
#define Program_ILLEGAL_UTF_8_INDEX 15
#define Program_INVALID_ARGUMENT_INDEX 16
#define Program_ALREADY_EXISTS_INDEX 10
#define Program_MALLOC_FAILED_INDEX 17
#define Program_CROSS_PROCESS_GC_INDEX 18
#define Program_OUT_OF_BOUNDS_INDEX 20
#define Program_OUT_OF_RANGE_INDEX 21
#define Program_WRONG_OBJECT_TYPE_INDEX 30
#define Program_WRONG_BYTES_TYPE_INDEX 31
#define Error_ERROR_SHIFT 2
#define Error_ERROR_TAG ((uword)3)

#define Scheduler_INVALID_PROCESS_ID (-1)

// class Utils.
#define Utils_MAX_ASCII 0x7f
#define Utils_MAX_TWO_BYTE_UNICODE 0x7ff
#define Utils_MAX_THREE_BYTE_UNICODE 0xffff
#define Utils_MIN_SURROGATE 0xd800
#define Utils_MAX_SURROGATE 0xdfff
#define Utils_UTF_8_PAYLOAD 0x80
#define Utils_UTF_8_BITS_PER_BYTE 6
#define Utils_UTF_8_MASK 0x3f

// src/messaging.h, src/messaging.cc.
#define MESSAGING_ENCODING_MAX_NESTING 8
#define TAG_POSITIVE_SMI 1
#define TAG_NEGATIVE_SMI 2
#define TAG_NULL 3
#define TAG_TRUE 4
#define TAG_FALSE 5
#define TAG_ARRAY 6
#define TAG_DOUBLE 7
#define TAG_LARGE_INTEGER 8
#define TAG_MAP 9
#define TAG_STRING 10
#define TAG_BYTE_ARRAY 12
#define TAG_STRING_INLINE 11
#define TAG_BYTE_ARRAY_INLINE 13
#define TAG_OVERFLOWN 0

// The encoders' limits and formats (src/messaging.h, messaging.cc).
#define MESSAGING_ENCODING_MAX_SIZE 0x3fffffff
#define MESSAGING_ENCODING_MAX_EXTERNALS 8
#define MESSAGING_ENCODING_MAX_INLINED_SIZE 128
#define MESSAGING_DECODING_MAX_NESTING 64
#define MESSAGE_FORMAT_IPC 0
#define MESSAGE_FORMAT_TISON 1
// The message types (src/messaging.h MessageType).
#define MESSAGE_MONITOR_NOTIFY 1
#define MESSAGE_SYSTEM 3
// The send results (src/messaging.h message_err_t).
#define MESSAGE_OK 0
#define MESSAGE_OOM 1
#define MESSAGE_NO_SUCH_RECEIVER 2
#define MESSAGE_PERMISSION_DENIED 3
#define MESSAGE_QUOTA_EXCEEDED 4
#define SYSTEM_RPC_REPLY 4
// The decoder (src/messaging.h MessageDecoder::Status, Smi limits, top.h).
#define MessageDecoder_DECODE_SUCCESS 0
#define MessageDecoder_DECODE_ALLOCATION_FAILED 1
#define MessageDecoder_DECODE_MALFORMED_INPUT 2
#define Smi_MAX_SMI_VALUE ((word)(UINTPTR_MAX / 4))
#define Smi_MIN_SMI_VALUE ((word)(-(word)(UINTPTR_MAX / 4) - 1))
#define WORD_BIT_SIZE ((int)(sizeof(word) * 8))
#define Instance_MAP_SPACES_LEFT_INDEX ((word)1)
#define Instance_MAP_INDEX_INDEX ((word)2)
#define TISON_MARKER ((uint32)0xa68900f7)
#define TISON_VERSION 1
#define TISON_VERSION_SHIFT ((uint32)8)
// Heap tags of the external copies (src/heap_report.h, top.h).
#define ITERATE_CUSTOM_TAGS ((word)-100)
#define EXTERNAL_BYTE_ARRAY_MALLOC_TAG ((uint8)1)
#define EXTERNAL_STRING_MALLOC_TAG ((uint8)3)
// The calendar of time_info (src/primitive_core.cc) and the 32-bit smi
// range (src/objects.h).
#define SECONDS_PER_DAY ((int64)86400)
#define Smi_MIN_SMI32_VALUE ((word)-1073741824)
#define MAX_BUFFER_SIZE_DOUBLE_TO_SHORTEST 26
#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define NUMBER_OF_POSSIBLE_OPERATIONS 6
#define OVERWRITE 0
#define OR 1
#define ADD 2
#define ADD_16_LE 3
#define AND 4
#define XOR 5
#define Smi_MAX_SMI32_VALUE ((word)1073741823)

#define V2_RECORD_ENTRY_SHIFT 8

#define NEW_SPACE_GC 0
#define FULL_GC 1
#define COMPACTING_GC 2

// Linux host page size on both verified ABIs.
#define TOIT_PAGE_SIZE_LOG2 15
#define TOIT_PAGE_SIZE 32768
#define MINIMUM_POST_GC_SPACE ((uword)(TOIT_PAGE_SIZE / 2))
#define ObjectHeap_ALLOCATION_SUCCESS 0
#define ObjectHeap_ALLOCATION_HIT_LIMIT 1
#define ObjectHeap__UNLIMITED_EXPANSION ((word)0x7fffffff)

#endif
