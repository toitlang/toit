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

# The verification epoch: a 32-bit number that identifies the install-time
# checks of untrusted programs and the interpreter contract they establish.
#
# The install-time verdict of an untrusted image (src/flash_allocation.h,
# FLAGS_PROGRAM_VERIFIED_MASK) is recorded with the epoch of the VM that
# computed it, and a VM takes a verdict only if its own epoch is the same
# (FlashAllocation::program_verified). After a firmware update to a build
# with another epoch, an installed untrusted image is treated as one without
# a verdict: it is refused (VERIFICATION_FAILED) until it is reinstalled.
#
# The epoch is computed from the sources, so it cannot be forgotten: it is
# the first 32 bits of SHA-256 over the manual component below and the
# SHA-256 of every input file (by path). Any change of an input file, even of
# a comment, gives a new epoch. The inputs are the sources that define:
#   - what the verifier accepts and what acceptance means: the spec crate
#     (the format-2 opcodes, `accepts`, `loaded_ok`, the certificate format
#     and its check) and the verifier glue that converts VM memory and runs
#     it (verified/vmverify);
#   - what the verified core assumes of an accepted program (the loader
#     theorem and the FFI entry that takes the verdict);
#   - the C++ install-time validation (src/verifier_v2.cc: image_layout_error,
#     builtin_classes_error, install_verdict; the method-table decoder) and
#     the layouts and tables it reads (Program, objects and tags, the
#     primitive arities, the opcode table), and the binding of the verdict
#     to the image (src/flash_allocation.*: the checksum, the certificate
#     block).
# What it does not cover: a bug in checks that did not change (the epoch says
# which checks ran, not that they are right); a relevant change in a file
# that is not an input (bump TOIT_VERIFICATION_EPOCH_MANUAL then, or add the
# file); build configurations (compiler flags, Kconfig options) and the Rust
# and C++ toolchains.
#
# The gate (verified/check.sh section `epoch`, `cmake -DMODE=check -P
# verified/verification-epoch.cmake`) fails when the epoch computed from the
# sources differs from TOIT_VERIFICATION_EPOCH_RECORDED: a change of the
# epoch, which makes every installed untrusted container need a reinstall
# after the firmware update, is then visible in the change that causes it.
# `-DMODE=update` writes the new value; `-DMODE=print` prints the epoch and
# the inputs.
#
# Used by src/CMakeLists.txt (include, toit_verification_epoch), which
# compiles the epoch into the VM (TOIT_VERIFICATION_EPOCH, flash_allocation.cc)
# and reconfigures when an input changes.

# Bump when something that is not an input changes what the install-time
# checks establish or what the interpreter assumes of a verified program.
set(TOIT_VERIFICATION_EPOCH_MANUAL 1)

# The digest of the inputs at the last review (MODE=update writes it); its
# first 8 digits are the epoch.
set(TOIT_VERIFICATION_EPOCH_RECORDED "79330a86ce00b0efbc4f577ddd7c471c4f8f38c8a45efbab03cfefe348c22633")

# Paths relative to the repository root; a pattern with a '*' is a recursive
# glob and must match a file, any other path must exist.
set(TOIT_VERIFICATION_EPOCH_INPUTS
  verified/spec/Cargo.toml
  verified/spec/src/*.rs
  verified/vmverify/Cargo.toml
  verified/vmverify/src/*.rs
  verified/core/src/theorem.rs
  verified/core/src/ffi.rs
  src/verifier_v2.cc
  src/verifier_v2.h
  src/v2_method_table.cc
  src/v2_compute_method_table.h
  src/v2_validate_records.h
  src/interpreter_v2.h
  src/program.h
  src/objects.h
  src/tags.h
  src/primitive.h
  src/bytecodes.h
  src/flash_allocation.h
  src/flash_allocation.cc
)

# Inputs left out again (regular expressions on the relative path): the
# crates' command-line tools, which never run on a device.
set(TOIT_VERIFICATION_EPOCH_EXCLUDES
  "^verified/spec/src/bin/"
  "^verified/vmverify/src/bin/"
)

# Computes the epoch of the sources under [root]: sets [out_epoch] to the
# epoch as 8 hex digits, [out_digest] to the full digest and [out_files] to
# the input files (relative paths). With CONFIGURE_DEPENDS, the globs are
# re-checked by the build (new files reconfigure).
function(toit_verification_epoch root out_epoch out_digest out_files)
  cmake_parse_arguments(PARSE_ARGV 4 ARG "CONFIGURE_DEPENDS" "" "")
  set(depends)
  if (ARG_CONFIGURE_DEPENDS)
    set(depends CONFIGURE_DEPENDS)
  endif()
  set(files)
  foreach(pattern ${TOIT_VERIFICATION_EPOCH_INPUTS})
    if (pattern MATCHES "\\*")
      file(GLOB_RECURSE matched ${depends} LIST_DIRECTORIES false RELATIVE "${root}" "${root}/${pattern}")
      if (NOT matched)
        message(FATAL_ERROR "verification epoch: no file matches '${pattern}' (verified/verification-epoch.cmake)")
      endif()
      list(APPEND files ${matched})
    elseif (EXISTS "${root}/${pattern}" AND NOT IS_DIRECTORY "${root}/${pattern}")
      list(APPEND files "${pattern}")
    else()
      message(FATAL_ERROR "verification epoch: missing input '${pattern}' (verified/verification-epoch.cmake)")
    endif()
  endforeach()
  foreach(exclude ${TOIT_VERIFICATION_EPOCH_EXCLUDES})
    list(FILTER files EXCLUDE REGEX "${exclude}")
  endforeach()
  list(REMOVE_DUPLICATES files)
  list(SORT files)
  set(text "toit verification epoch\nmanual ${TOIT_VERIFICATION_EPOCH_MANUAL}\n")
  foreach(file ${files})
    file(SHA256 "${root}/${file}" hash)
    string(APPEND text "${hash}  ${file}\n")
  endforeach()
  string(SHA256 digest "${text}")
  string(SUBSTRING "${digest}" 0 8 epoch)
  set(${out_epoch} "${epoch}" PARENT_SCOPE)
  set(${out_digest} "${digest}" PARENT_SCOPE)
  set(${out_files} "${files}" PARENT_SCOPE)
endfunction()

# Script mode: cmake [-DTOIT_SOURCE_DIR=ROOT] -DMODE=check|update|print -P verified/verification-epoch.cmake
if (CMAKE_SCRIPT_MODE_FILE STREQUAL CMAKE_CURRENT_LIST_FILE)
  if (NOT TOIT_SOURCE_DIR)
    get_filename_component(TOIT_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
  endif()
  if (NOT MODE)
    set(MODE check)
  endif()
  toit_verification_epoch("${TOIT_SOURCE_DIR}" epoch digest files)
  if (MODE STREQUAL "print")
    foreach(file ${files})
      message("  ${file}")
    endforeach()
    list(LENGTH files count)
    message("verification epoch ${epoch} (${count} inputs, manual ${TOIT_VERIFICATION_EPOCH_MANUAL})")
  elseif (MODE STREQUAL "check")
    if (NOT digest STREQUAL TOIT_VERIFICATION_EPOCH_RECORDED)
      string(SUBSTRING "${TOIT_VERIFICATION_EPOCH_RECORDED}" 0 8 recorded)
      message("verification epoch: ${recorded} recorded, ${epoch} computed: an input of the "
              "install-time checks changed (verified/verification-epoch.cmake lists them). Untrusted "
              "containers installed by a firmware with the old epoch are refused after an update to "
              "this one until they are reinstalled. If that is intended, record the new epoch with "
              "'cmake -DMODE=update -P verified/verification-epoch.cmake', and bump "
              "TOIT_VERIFICATION_EPOCH_MANUAL if a change outside the inputs needs it.")
      message(FATAL_ERROR "verification epoch changed")
    endif()
    message("verification epoch ${epoch}: recorded")
  elseif (MODE STREQUAL "update")
    file(READ "${CMAKE_CURRENT_LIST_FILE}" content)
    string(REGEX REPLACE "set\\(TOIT_VERIFICATION_EPOCH_RECORDED \"[0-9a-f]*\"\\)"
           "set(TOIT_VERIFICATION_EPOCH_RECORDED \"${digest}\")" content "${content}")
    file(WRITE "${CMAKE_CURRENT_LIST_FILE}" "${content}")
    message("verification epoch ${epoch}: recorded in ${CMAKE_CURRENT_LIST_FILE}")
  else()
    message(FATAL_ERROR "MODE must be check, update or print, not '${MODE}'")
  endif()
endif()
