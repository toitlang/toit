# Copyright (C) 2026 Toit contributors.
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

# Self-test of the verification-epoch gate (verified/verification-epoch.cmake,
# verified/check.sh sections `epoch` and `epoch-self-test`).
#
# On a copy of the epoch's inputs in WORK: the gate passes on the copy as it
# is; it fails after an input changes (an edit, a new file under a glob, a
# removed file) or the manual component is bumped, until the new epoch is
# recorded (MODE=update), which gives another epoch; a file in an excluded
# directory does not change the epoch. With EXPECTED_EPOCH (the epoch a build
# was configured with), also checks that the build's epoch is the one of the
# sources.
#
# Usage: cmake -DWORK=DIR [-DEXPECTED_EPOCH=HEX] -P verified/tools/verification-epoch-self-test.cmake

cmake_minimum_required(VERSION 3.16)

get_filename_component(REPO "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
if (NOT WORK)
  message(FATAL_ERROR "WORK is not set")
endif()

include("${REPO}/verified/verification-epoch.cmake")
toit_verification_epoch("${REPO}" source_epoch source_digest files)

if (EXPECTED_EPOCH)
  if (NOT EXPECTED_EPOCH STREQUAL source_epoch)
    message(FATAL_ERROR "the build's verification epoch ${EXPECTED_EPOCH} is not the sources' ${source_epoch}: reconfigure")
  endif()
  message("the build's verification epoch is the sources' (${source_epoch})")
endif()

file(REMOVE_RECURSE "${WORK}")
file(MAKE_DIRECTORY "${WORK}/verified")
foreach(file ${files})
  get_filename_component(directory "${WORK}/${file}" DIRECTORY)
  file(COPY "${REPO}/${file}" DESTINATION "${directory}")
endforeach()
set(manifest "${WORK}/verified/verification-epoch.cmake")
file(COPY "${REPO}/verified/verification-epoch.cmake" DESTINATION "${WORK}/verified")

set(failures 0)

# Runs the gate in MODE on the copy; [expect] is "pass" or "fail"; [what]
# describes the case. A failure must come with [message] in the output.
function(gate mode expect what)
  cmake_parse_arguments(PARSE_ARGV 3 ARG "" "MESSAGE" "")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -DMODE=${mode} -P "${manifest}"
    RESULT_VARIABLE result OUTPUT_VARIABLE out ERROR_VARIABLE out)
  if (expect STREQUAL "pass" AND NOT result EQUAL 0)
    message("FAIL: ${what}: the gate failed:\n${out}")
    math(EXPR count "${failures} + 1")
    set(failures ${count} PARENT_SCOPE)
  elseif (expect STREQUAL "fail" AND result EQUAL 0)
    message("FAIL: ${what}: the gate passed:\n${out}")
    math(EXPR count "${failures} + 1")
    set(failures ${count} PARENT_SCOPE)
  elseif (expect STREQUAL "fail" AND ARG_MESSAGE AND NOT out MATCHES "${ARG_MESSAGE}")
    message("FAIL: ${what}: the gate failed without '${ARG_MESSAGE}':\n${out}")
    math(EXPR count "${failures} + 1")
    set(failures ${count} PARENT_SCOPE)
  else()
    message("ok: ${what}")
  endif()
endfunction()

# The epoch the copy's manifest records.
function(recorded out)
  file(STRINGS "${manifest}" line REGEX "^set\\(TOIT_VERIFICATION_EPOCH_RECORDED ")
  string(REGEX REPLACE ".*\"([0-9a-f]*)\".*" "\\1" digest "${line}")
  string(SUBSTRING "${digest}" 0 8 epoch)
  set(${out} "${epoch}" PARENT_SCOPE)
endfunction()

# The copy as it is. (The gate passes on the repository too, if its recorded
# digest is current: that is section `epoch`, not this test.)
gate(update pass "record the copy's epoch")
gate(check pass "unchanged inputs")
recorded(start)
if (NOT start STREQUAL source_epoch)
  message("FAIL: the copy's epoch ${start} is not the sources' ${source_epoch}")
  math(EXPR failures "${failures} + 1")
endif()

# An edit of a C++ input (a comment): the epoch changes.
file(APPEND "${WORK}/src/verifier_v2.cc" "// An edit.\n")
gate(check fail "edited src/verifier_v2.cc" MESSAGE "verification epoch changed")
gate(update pass "record after the edit")
gate(check pass "recorded after the edit")
recorded(after_edit)
if (after_edit STREQUAL start)
  message("FAIL: the epoch did not change with an input")
  math(EXPR failures "${failures} + 1")
endif()

# A new file under a glob (a new module of the verifier).
file(WRITE "${WORK}/verified/vmverify/src/new_check.rs" "// A new check.\n")
gate(check fail "new verified/vmverify/src/new_check.rs" MESSAGE "verification epoch changed")
gate(update pass "record the new file")

# A file in an excluded directory (a command-line tool of the spec crate).
file(WRITE "${WORK}/verified/spec/src/bin/new_tool.rs" "fn main() {}\n")
gate(check pass "new file in verified/spec/src/bin (excluded)")

# A Rust spec input edited.
file(APPEND "${WORK}/verified/spec/src/v2/check.rs" "// An edit.\n")
gate(check fail "edited verified/spec/src/v2/check.rs" MESSAGE "verification epoch changed")
gate(update pass "record the spec edit")

# The manual component bumped.
file(READ "${manifest}" content)
string(REPLACE "set(TOIT_VERIFICATION_EPOCH_MANUAL 1)" "set(TOIT_VERIFICATION_EPOCH_MANUAL 2)" content "${content}")
file(WRITE "${manifest}" "${content}")
gate(check fail "manual component bumped" MESSAGE "verification epoch changed")
gate(update pass "record the bump")
gate(check pass "recorded after the bump")

# A listed input removed (renamed): the gate cannot compute the epoch.
file(RENAME "${WORK}/src/verifier_v2.h" "${WORK}/src/verifier_v2_renamed.h")
gate(check fail "removed src/verifier_v2.h" MESSAGE "missing input 'src/verifier_v2.h'")

file(REMOVE_RECURSE "${WORK}")
if (NOT failures EQUAL 0)
  message(FATAL_ERROR "verification-epoch self-test: ${failures} failures")
endif()
message("verification-epoch self-test passed")
