# Copyright (C) 2021 Toitware ApS.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

set(TOIT_FAILING_TESTS
)


if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows")
  list(APPEND TOIT_FAILING_TESTS
    tests/lsp/assig_completion_test.toit
    tests/lsp/basic_completion_test.toit
    tests/lsp/export_completion_test.toit
    tests/lsp/extends_implements_completion_test.toit
    tests/lsp/field_completion_test.toit
    tests/lsp/field_storing_completion_test.toit
    tests/lsp/filtered_completion_test.toit
    tests/lsp/import_completion_test.toit
    tests/lsp/incomplete_completion_test.toit
    tests/lsp/kind_completion_test.toit
    tests/lsp/lambda_block_completion_test.toit
    tests/lsp/member_completion_test.toit
    tests/lsp/named_completion_test.toit
    tests/lsp/pkg/pkg_completion_test.toit
    tests/lsp/pkg/target/src/target_completion_test.toit
    tests/lsp/prefix_completion_test.toit
    tests/lsp/primitive_completion_test.toit
    tests/lsp/return_label_completion_test.toit
    tests/lsp/show_bad_completion_test.toit
    tests/lsp/show_completion_test.toit
    tests/lsp/static2_completion_test.toit
    tests/lsp/static_completion_test.toit
    tests/lsp/this_super_completion_test.toit
    tests/lsp/toitdoc_completion_test.toit
    tests/lsp/type_completion_test.toit
    tests/lsp/assig_definition_test.toit
    tests/lsp/bad_definition_test.toit
    tests/lsp/basic_definition_test.toit
    tests/lsp/export_definition_test.toit
    tests/lsp/extends_implements_definition_test.toit
    tests/lsp/field_definition_test.toit
    tests/lsp/field_storing_definition_test.toit
    tests/lsp/import_definition_test.toit
    tests/lsp/keyword_definition_test.toit
    tests/lsp/lambda_block_definition_test.toit
    tests/lsp/member_definition_test.toit
    tests/lsp/pkg/pkg_definition_test.toit
    tests/lsp/pkg/target/src/target_definition_test.toit
    tests/lsp/prefix_definition_test.toit
    tests/lsp/return_label_definition_test.toit
    tests/lsp/show_definition_test.toit
    tests/lsp/static_definition_test.toit
    tests/lsp/this_super_definition_test.toit
    tests/lsp/toitdoc_definition_test.toit
    tests/lsp/type_definition_test.toit
    tests/lsp/cancel_compiler_test.toit
    tests/lsp/config2_compiler_test.toit
    tests/lsp/config_compiler_test.toit
    tests/lsp/crash_compiler_test.toit
    tests/lsp/crash_rate_limit_compiler_test.toit
    tests/lsp/dep2_compiler_test.toit
    tests/lsp/dep3_compiler_test.toit
    tests/lsp/dep3b_compiler_test.toit
    tests/lsp/dep4_compiler_test.toit
    tests/lsp/dep5_compiler_test.toit
    tests/lsp/dep6_compiler_test.toit
    tests/lsp/dep7_compiler_test.toit
    tests/lsp/dep8_compiler_test.toit
    tests/lsp/dep9_compiler_test.toit
    tests/lsp/depA_compiler_test.toit
    tests/lsp/dep_compiler_test.toit
    tests/lsp/double_import_compiler_test.toit
    tests/lsp/dump_crash_compiler_test.toit
    tests/lsp/error_compiler_test.toit
    tests/lsp/export_summary_compiler_test.toit
    tests/lsp/incomplete_compiler_test.toit
    tests/lsp/invalid_symbol_compiler_test.toit
    tests/lsp/lsp_filesystem_compiler_test.toit
    tests/lsp/lsp_ubjson_rpc_compiler_test.toit
    tests/lsp/null_char_compiler_test.toit
    tests/lsp/open_many_compiler_test.toit
    tests/lsp/outline_compiler_test.toit
    tests/lsp/parser_recursion_depth_compiler_test.toit
    tests/lsp/project_root_compiler_test.toit
    tests/lsp/save_error_compiler_test.toit
    tests/lsp/semantic_tokens_compiler_test.toit
    tests/lsp/slow_compiler_test.toit
    tests/lsp/snapshot_compiler_test.toit
    tests/lsp/space_compiler_test.toit
    tests/lsp/summary_compiler_test.toit
    tests/lsp/timeout_compiler_test.toit
    tests/lsp/toitdoc2_compiler_test.toit
    tests/lsp/toitdoc3_compiler_test.toit
    tests/lsp/toitdoc4_compiler_test.toit
    tests/lsp/toitdoc_compiler_test.toit
    tests/lsp/underscore_compiler_test.toit
    tests/lsp/utf_16_compiler_test.toit
    tests/lsp/warning_compiler_test.toit
    tests/lsp/big_file_compiler_test_slow.toit
    tests/lsp/file_check_compiler_test_slow.toit
    tests/lsp/lsp_stress_compiler_test_slow.toit
    tests/lsp/mock_compiler_test_slow.toit
    tests/lsp/protocol_compiler_test_slow.toit
    tests/lsp/repro_compiler_test_slow.toit
  )
endif()
