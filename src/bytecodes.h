// Copyright (C) 2018 Toitware ApS.
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

#pragma once

#include "top.h"

namespace toit {

// Terms used in BYTECODE_FORMAT:
//   OP = uint8: opcode
//   BU = uint8: unsigned value
//   BS = uint8: stack offset
//   BL = uint8: literal index
//   BC = uint8: class index
//   BG = uint8: global index
//   BF = uint8: relative bci offset
//   BB = uint8: relative bci offset backward
//   BCI = uint8: encoded  into class_check_id-table
//   BII = uint8: encoded index into interface_check_offset-table
//   BLC = uint8: encoded local and class_check_id-table index.
//   SU = uint16: unsigned value
//   SS = uint16: stack offset
//   SL = uint16: literal index
//   SC = uint16: class index
//   SG = uint16: global index
//   SF = uint16: relative bci offset
//   SB = uint16: relative bci offset backward
//   SCI = uint16: encoded index into class_check_id-table
//   SII = uint16: encoded index into interface_check_offset-table
//   SD = uint16: dispatch table offset
//   SO = uint16: selector offset
//   WU = uint32: unsigned value

#define BYTECODE_FORMATS(FORMAT) \
  FORMAT(OP, 1)                  \
  FORMAT(OP_BU, 2)               \
  FORMAT(OP_BS, 2)               \
  FORMAT(OP_BL, 2)               \
  FORMAT(OP_BC, 2)               \
  FORMAT(OP_BG, 2)               \
  FORMAT(OP_BF, 2)               \
  FORMAT(OP_BB, 2)               \
  FORMAT(OP_BCI, 2)              \
  FORMAT(OP_BII, 2)              \
  FORMAT(OP_BLC, 2)              \
  FORMAT(OP_SU, 3)               \
  FORMAT(OP_SF, 3)               \
  FORMAT(OP_BS_BU, 3)            \
  FORMAT(OP_SD, 3)               \
  FORMAT(OP_SO, 3)               \
  FORMAT(OP_WU, 5)               \
  FORMAT(OP_BS_SO, 4)            \
  FORMAT(OP_BU_SO, 4)            \
  FORMAT(OP_BU_SU, 4)            \
  FORMAT(OP_BU_WU, 6)            \
  FORMAT(OP_SD_BS_BU, 5)         \
  FORMAT(OP_SS, 3)               \
  FORMAT(OP_SL, 3)               \
  FORMAT(OP_SG, 3)               \
  FORMAT(OP_SC, 3)               \
  FORMAT(OP_SS_SO, 5)            \
  FORMAT(OP_SCI, 3)              \
  FORMAT(OP_SII, 3)              \
  FORMAT(OP_SB, 3)               \
  FORMAT(OP_SU_SU, 5)            \



// Format Toit bytecodes
enum BytecodeFormat {
#define THE_FORMAT(format, length) format,
  BYTECODE_FORMATS(THE_FORMAT)
#undef BYTECODE_PRINT
};

// Macro for iterating over the bytecode definitions.
#define BYTECODES(BYTECODE)                                                    \
  BYTECODE(LOAD_LOCAL,                 2, OP_BS, "load local")                 \
  BYTECODE(LOAD_LOCAL_WIDE,            3, OP_SS, "load local wide")            \
  BYTECODE(POP_LOAD_LOCAL,             2, OP_BS, "pop, load local")            \
  BYTECODE(STORE_LOCAL,                2, OP_BS, "store local")                \
  BYTECODE(STORE_LOCAL_POP,            2, OP_BS, "store local, pop")           \
  BYTECODE(LOAD_OUTER,                 2, OP_BS, "load outer")                 \
  BYTECODE(STORE_OUTER,                2, OP_BS, "store outer")                \
  BYTECODE(LOAD_FIELD,                 2, OP_BU, "load field")                 \
  BYTECODE(LOAD_FIELD_WIDE,            3, OP_SU, "load field wide")            \
  BYTECODE(LOAD_FIELD_LOCAL,           2, OP_BU, "load field local")           \
  BYTECODE(POP_LOAD_FIELD_LOCAL,       2, OP_BU, "pop, load field local")      \
  BYTECODE(STORE_FIELD,                2, OP_BU, "store field")                \
  BYTECODE(STORE_FIELD_WIDE,           3, OP_SU, "store field wide")           \
  BYTECODE(STORE_FIELD_POP,            2, OP_BU, "store field, pop")           \
  \
  BYTECODE(LOAD_LOCAL_0,               1, OP, "load local 0")                  \
  BYTECODE(LOAD_LOCAL_1,               1, OP, "load local 1")                  \
  BYTECODE(LOAD_LOCAL_2,               1, OP, "load local 2")                  \
  BYTECODE(LOAD_LOCAL_3,               1, OP, "load local 3")                  \
  BYTECODE(LOAD_LOCAL_4,               1, OP, "load local 4")                  \
  BYTECODE(LOAD_LOCAL_5,               1, OP, "load local 5")                  \
  \
  BYTECODE(LOAD_LITERAL,               2, OP_BL, "load literal")               \
  BYTECODE(LOAD_LITERAL_WIDE,          3, OP_SL, "load literal wide")          \
  BYTECODE(LOAD_NULL,                  1, OP, "load null")                     \
  BYTECODE(LOAD_SMI_0,                 1, OP, "load smi 0")                    \
  BYTECODE(LOAD_SMIS_0,                2, OP_BU, "load smis 0")                \
  BYTECODE(LOAD_SMI_1,                 1, OP, "load smi 1")                    \
  BYTECODE(LOAD_SMI_U8,                2, OP_BU, "load smi")                   \
  BYTECODE(LOAD_SMI_U16,               3, OP_SU, "load smi")                   \
  BYTECODE(LOAD_SMI_U32,               5, OP_WU, "load smi")                   \
  \
  BYTECODE(LOAD_GLOBAL_VAR,            2, OP_BG, "load global var")            \
  BYTECODE(LOAD_GLOBAL_VAR_DYNAMIC,    1, OP,    "load global var dynamic")    \
  BYTECODE(LOAD_GLOBAL_VAR_WIDE,       3, OP_SG, "load global var wide")       \
  BYTECODE(LOAD_GLOBAL_VAR_LAZY,       2, OP_BG, "load global var lazy")       \
  BYTECODE(LOAD_GLOBAL_VAR_LAZY_WIDE,  3, OP_SG, "load global var lazy wide")  \
  BYTECODE(STORE_GLOBAL_VAR,           2, OP_BG, "store global var")           \
  BYTECODE(STORE_GLOBAL_VAR_WIDE,      3, OP_SG, "store global var wide")      \
  BYTECODE(STORE_GLOBAL_VAR_DYNAMIC,   1, OP,    "store global var dynamic")   \
  BYTECODE(LOAD_BLOCK,                 2, OP_BU, "load block")                 \
  BYTECODE(LOAD_OUTER_BLOCK,           2, OP_BU, "load outer block")           \
  \
  BYTECODE(POP,                        2, OP_BU, "pop")                        \
  BYTECODE(POP_1,                      1, OP, "pop 1")                         \
  \
  BYTECODE(ALLOCATE,                   2, OP_BC, "allocate instance")          \
  BYTECODE(ALLOCATE_WIDE,              3, OP_SC, "allocate instance wide")     \
  \
  BYTECODE(IS_CLASS,                   2, OP_BCI, "is class")                  \
  BYTECODE(IS_CLASS_WIDE,              3, OP_SCI, "is class wide")             \
  BYTECODE(IS_INTERFACE,               2, OP_BII, "is interface")              \
  BYTECODE(IS_INTERFACE_WIDE,          3, OP_SII, "is interface wide")         \
  BYTECODE(AS_CLASS,                   2, OP_BCI, "as class")                  \
  BYTECODE(AS_CLASS_WIDE,              3, OP_SCI, "as class wide")             \
  BYTECODE(AS_INTERFACE,               2, OP_BII, "as interface")              \
  BYTECODE(AS_INTERFACE_WIDE,          3, OP_SII, "as interface wide")         \
  BYTECODE(AS_LOCAL,                   2, OP_BLC, "load local, as, pop")       \
  \
  BYTECODE(INVOKE_STATIC,              3, OP_SD, "invoke static")              \
  BYTECODE(INVOKE_STATIC_TAIL,         5, OP_SD_BS_BU, "invoke static tail")   \
  BYTECODE(INVOKE_BLOCK,               2, OP_BS, "invoke block")               \
  BYTECODE(INVOKE_LAMBDA_TAIL,         2, OP_BF, "invoke lambda tail")         \
  BYTECODE(INVOKE_INITIALIZER_TAIL,    3, OP_BS_BU, "invoke initializer tail") \
  \
  BYTECODE(INVOKE_VIRTUAL,             4, OP_BS_SO, "invoke virtual")          \
  BYTECODE(INVOKE_VIRTUAL_WIDE,        5, OP_SS_SO, "invoke virtual wide")     \
  BYTECODE(INVOKE_VIRTUAL_GET,         3, OP_SO, "invoke virtual get")         \
  BYTECODE(INVOKE_VIRTUAL_SET,         3, OP_SO, "invoke virtual set")         \
  \
  BYTECODE(INVOKE_EQ,                  1, OP, "invoke eq")                     \
  BYTECODE(INVOKE_LT,                  1, OP, "invoke lt")                     \
  BYTECODE(INVOKE_GT,                  1, OP, "invoke gt")                     \
  BYTECODE(INVOKE_LTE,                 1, OP, "invoke lte")                    \
  BYTECODE(INVOKE_GTE,                 1, OP, "invoke gte")                    \
  BYTECODE(INVOKE_BIT_OR,              1, OP, "invoke bit or")                 \
  BYTECODE(INVOKE_BIT_XOR,             1, OP, "invoke bit xor")                \
  BYTECODE(INVOKE_BIT_AND,             1, OP, "invoke bit and")                \
  BYTECODE(INVOKE_BIT_SHL,             1, OP, "invoke bit shl")                \
  BYTECODE(INVOKE_BIT_SHR,             1, OP, "invoke bit shr")                \
  BYTECODE(INVOKE_BIT_USHR,            1, OP, "invoke bit ushr")               \
  BYTECODE(INVOKE_ADD,                 1, OP, "invoke add")                    \
  BYTECODE(INVOKE_SUB,                 1, OP, "invoke sub")                    \
  BYTECODE(INVOKE_MUL,                 1, OP, "invoke mul")                    \
  BYTECODE(INVOKE_DIV,                 1, OP, "invoke div")                    \
  BYTECODE(INVOKE_MOD,                 1, OP, "invoke mod")                    \
  BYTECODE(INVOKE_AT,                  1, OP, "invoke at")                     \
  BYTECODE(INVOKE_AT_PUT,              1, OP, "invoke at_put")                 \
  \
  BYTECODE(BRANCH,                     3, OP_SF, "branch")                     \
  BYTECODE(BRANCH_IF_TRUE,             3, OP_SF, "branch if true")             \
  BYTECODE(BRANCH_IF_FALSE,            3, OP_SF, "branch if false")            \
  BYTECODE(BRANCH_BACK,                2, OP_BB, "branch back")                \
  BYTECODE(BRANCH_BACK_WIDE,           3, OP_SB, "branch back wide")           \
  BYTECODE(BRANCH_BACK_IF_TRUE,        2, OP_BB, "branch back if true")        \
  BYTECODE(BRANCH_BACK_IF_TRUE_WIDE,   3, OP_SB, "branch back if true wide")   \
  BYTECODE(BRANCH_BACK_IF_FALSE,       2, OP_BB, "branch back if false")       \
  BYTECODE(BRANCH_BACK_IF_FALSE_WIDE,  3, OP_SB, "branch back if false wide")  \
  BYTECODE(PRIMITIVE,                  4, OP_BU_SU, "invoke primitive")        \
  BYTECODE(THROW,                      2, OP_BU, "throw")                      \
  BYTECODE(RETURN,                     3, OP_BS_BU, "return")                  \
  BYTECODE(RETURN_NULL,                3, OP_BS_BU, "return null")             \
  BYTECODE(NON_LOCAL_RETURN,           2, OP_BU, "non-local return")           \
  BYTECODE(NON_LOCAL_RETURN_WIDE,      4, OP_SU_SU, "non-local return wide")   \
  BYTECODE(NON_LOCAL_BRANCH,           6, OP_BU_WU, "non-local branch")        \
  BYTECODE(LINK,                       2, OP_BU, "link try")                   \
  BYTECODE(UNLINK,                     2, OP_BU, "unlink try")                 \
  BYTECODE(UNWIND,                     1, OP, "unwind")                        \
  BYTECODE(HALT,                       2, OP_BU, "halt")                       \
  \
  BYTECODE(INTRINSIC_SMI_REPEAT,       1, OP, "intrinsic smi repeat")          \
  BYTECODE(INTRINSIC_ARRAY_DO,         1, OP, "intrinsic array do")            \
  BYTECODE(INTRINSIC_HASH_FIND,        1, OP, "intrinsic hash find")           \
  BYTECODE(INTRINSIC_HASH_DO,          1, OP, "intrinsic hash do")             \

#define BYTECODE_ENUM(name, length, format, print) name,
enum Opcode { BYTECODES(BYTECODE_ENUM) ILLEGAL_END };
#undef BYTECODE_ENUM

#define BYTECODE_ENUM(name, length, format, print) static const int name##_LENGTH = length;
BYTECODES(BYTECODE_ENUM)
#undef BYTECODE_ENUM

} // namespace toit
