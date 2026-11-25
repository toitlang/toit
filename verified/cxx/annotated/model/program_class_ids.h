// Copyright (C) 2026 Toit contributors.

#ifndef TOIT_VF_PROGRAM_CLASS_IDS_H
#define TOIT_VF_PROGRAM_CLASS_IDS_H

// Shared with the native equivalence harness. Each alias calls the rendered indexed getter.
#define Program_array_class_id_INDEX 1
#define Program_array_class_id(p) Program_class_id(p, Program_array_class_id_INDEX)
#define Program_list_class_id_INDEX 7
#define Program_list_class_id(p) Program_class_id(p, Program_list_class_id_INDEX)
#define Program_list_slice_class_id_INDEX 8
#define Program_list_slice_class_id(p) Program_class_id(p, Program_list_slice_class_id_INDEX)
#define Program_map_class_id_INDEX 9
#define Program_map_class_id(p) Program_class_id(p, Program_map_class_id_INDEX)
#define Program_large_array_class_id_INDEX 20
#define Program_large_array_class_id(p) Program_class_id(p, Program_large_array_class_id_INDEX)
#define Program_tombstone_class_id_INDEX 10
#define Program_tombstone_class_id(p) Program_class_id(p, Program_tombstone_class_id_INDEX)
#define Program_byte_array_cow_class_id_INDEX 3
#define Program_byte_array_cow_class_id(p) Program_class_id(p, Program_byte_array_cow_class_id_INDEX)
#define Program_byte_array_slice_class_id_INDEX 4
#define Program_byte_array_slice_class_id(p) Program_class_id(p, Program_byte_array_slice_class_id_INDEX)
#define Program_string_byte_slice_class_id_INDEX 6
#define Program_string_byte_slice_class_id(p) Program_class_id(p, Program_string_byte_slice_class_id_INDEX)
#define Program_string_slice_class_id_INDEX 5
#define Program_string_slice_class_id(p) Program_class_id(p, Program_string_slice_class_id_INDEX)
// The others (wave 12: the install-time check of every builtin class,
// loader/builtin_classes.render).
#define Program_string_class_id_INDEX 0
#define Program_string_class_id(p) Program_class_id(p, Program_string_class_id_INDEX)
#define Program_byte_array_class_id_INDEX 2
#define Program_byte_array_class_id(p) Program_class_id(p, Program_byte_array_class_id_INDEX)
#define Program_stack_class_id_INDEX 11
#define Program_stack_class_id(p) Program_class_id(p, Program_stack_class_id_INDEX)
#define Program_null_class_id_INDEX 12
#define Program_null_class_id(p) Program_class_id(p, Program_null_class_id_INDEX)
#define Program_true_class_id_INDEX 13
#define Program_true_class_id(p) Program_class_id(p, Program_true_class_id_INDEX)
#define Program_false_class_id_INDEX 14
#define Program_false_class_id(p) Program_class_id(p, Program_false_class_id_INDEX)
#define Program_object_class_id_INDEX 15
#define Program_object_class_id(p) Program_class_id(p, Program_object_class_id_INDEX)
#define Program_double_class_id_INDEX 16
#define Program_double_class_id(p) Program_class_id(p, Program_double_class_id_INDEX)
#define Program_large_integer_class_id_INDEX 17
#define Program_large_integer_class_id(p) Program_class_id(p, Program_large_integer_class_id_INDEX)
#define Program_smi_class_id_INDEX 18
#define Program_smi_class_id(p) Program_class_id(p, Program_smi_class_id_INDEX)
#define Program_task_class_id_INDEX 19
#define Program_task_class_id(p) Program_class_id(p, Program_task_class_id_INDEX)
#define Program_lazy_initializer_class_id_INDEX 21
#define Program_lazy_initializer_class_id(p) Program_class_id(p, Program_lazy_initializer_class_id_INDEX)
#define Program_exception_class_id_INDEX 22
#define Program_exception_class_id(p) Program_class_id(p, Program_exception_class_id_INDEX)

#endif
