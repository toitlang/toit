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

// class Object.
#define SMI_TAG_SIZE 1
#define Object_SMI_TAG_MASK ((uword)1)
#define Object_SMI_TAG ((uword)0)
#define Object_NON_SMI_TAG_MASK ((uword)3)
#define Object_HEAP_TAG ((uword)1)
#define HEAP_TAG ((uword)1)

// class HeapObject.
#define HEADER_OFFSET ((word)0)
#define HeapObject_CLASS_ID_OFFSET ((word)5)
#define HeapObject_CLASS_ID_MASK ((uword)UINTPTR_MAX)
#define HeapObject_CLASS_TAG_OFFSET ((word)0)
#define HeapObject_CLASS_TAG_MASK ((uword)15)

// class Instance, class Array.
#define Instance_HEADER_SIZE ((word)sizeof(word))
#define Instance_LIST_ARRAY_INDEX ((word)0)
#define Instance_LIST_SIZE_INDEX ((word)1)
#define Instance_LIST_SLICE_LIST_INDEX ((word)0)
#define Instance_LIST_SLICE_FROM_INDEX ((word)1)
#define Instance_LIST_SLICE_TO_INDEX ((word)2)
#define Instance_MAP_SIZE_INDEX ((word)0)
#define Instance_MAP_BACKING_INDEX ((word)3)
#define Array_LENGTH_OFFSET ((word)sizeof(word))
#define Array_HEADER_SIZE ((word)(2 * sizeof(word)))

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

// class Utils.
#define Utils_MAX_ASCII 0x7f
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

#endif
