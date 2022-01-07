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

# Load the git package giving us 'GIT_EXECUTABLE'
find_package(Git QUIET REQUIRED)

function(backtick out_name)
  execute_process(
    COMMAND ${ARGN}
    OUTPUT_VARIABLE result
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
  )
  set(${out_name} ${result} PARENT_SCOPE)
endfunction()

function(compute_git_version VERSION)
  # Check that we are in a git tree.
  backtick(ignored ${GIT_EXECUTABLE} rev-parse --is-inside-work-tree)

  backtick(CURRENT_COMMIT ${GIT_EXECUTABLE} rev-parse HEAD)
  backtick(CURRENT_COMMIT_SHORT ${GIT_EXECUTABLE} rev-parse --short HEAD)

  # We assume that there is always a version, and don't handle the initial case where no
  # version tag is found.

  # Note: the clone of the repository must have access to all tags.
  # Buildbots might provide a shallow copy, in which case `git fetch --tags` must be called.

  backtick(TAG_COMMIT ${GIT_EXECUTABLE} rev-list --tags --max-count=1)
  # The '--abbrev=0' ensures that we only get the tag, without the number of intermediate commits.
  # The buildbot has a shallow checkout of our repository. We need to pass in the commit of the latest tag.
  # (Tbh not sure why.)
  backtick(LATEST_VERSION_TAG ${GIT_EXECUTABLE} describe --tags --match "v[0-9]*" --abbrev=0 ${TAG_COMMIT})

  backtick(VERSION_TAG_COMMIT ${GIT_EXECUTABLE} rev-parse "${LATEST_VERSION_TAG}^{}")

  if ("${VERSION_TAG_COMMIT}" STREQUAL "${CURRENT_COMMIT}")
    set(${VERSION} "${LATEST_VERSION_TAG}" PARENT_SCOPE)
    return()
  endif()

  set(SEMVER_REGEX "^v([0-9]+)\\.([0-9]+)\\.([0-9]+)")
  string(REGEX REPLACE ${SEMVER_REGEX} "\\1" major ${LATEST_VERSION_TAG})
  string(REGEX REPLACE ${SEMVER_REGEX} "\\2" minor ${LATEST_VERSION_TAG})
  string(REGEX REPLACE ${SEMVER_REGEX} "\\3" patch ${LATEST_VERSION_TAG})

  backtick(CURRENT_COMMIT_NO ${GIT_EXECUTABLE} rev-list --count HEAD "^${VERSION_TAG_COMMIT}")
  backtick(CURRENT_BRANCH ${GIT_EXECUTABLE} rev-parse --abbrev-ref HEAD)

  if ("${CURRENT_BRANCH}" MATCHES "^release-v[0-9]+\\.[0-9]$")
    # Use next patch version when on a release branch.
    MATH(EXPR patch "${patch}+1")
    set(${VERSION} "v${major}.${minor}.${patch}-pre.${CURRENT_COMMIT_NO}+${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
    return()
  endif()

  if ("${CURRENT_BRANCH}" MATCHES "^release-v[0-9]+\\.[0-9]$")
    # Master branch: v0.5.0-pre.17+9a1fbdb29
    MATH(EXPR minor "${minor}+1")
    set(${VERSION} "v${major}.${minor}.0-pre.${CURRENT_COMMIT_NO}+${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
    return()
  endif()

  # Other branch: v0.5.0-pre.17+branch-name.9a1fbd29
  # Semver requires the dot-separated identifiers to comprise only alphanumerics and hyphens.
  string(REGEX REPLACE "[^.0-9A-Za-z-]" "-" SANITIZED_BRANCH ${CURRENT_BRANCH})
  MATH(EXPR minor "${minor}+1")
  set(${VERSION} "v${major}.${minor}.0-pre.${CURRENT_COMMIT_NO}+${SANITIZED_BRANCH}.${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
endfunction()

# Print the git-version on stdout:
# cmake -DPRINT_VERSION=1 -P tools/gitversion.cmake
if (DEFINED PRINT_VERSION)
  compute_git_version(VERSION)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${VERSION}")
endif()
