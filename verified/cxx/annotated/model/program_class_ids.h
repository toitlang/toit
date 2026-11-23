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

#endif
