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

  # On the main-branch we want to use the highest version-number+1.
  # However, if a version was branched but not released yet, then we don't have a tag yet.
  # Run through the branches to see if there is a branch in preparation.
  backtick(ALL_BRANCHES ${GIT_EXECUTABLE} branch -a "--format=%(refname:short)")
  # Split lines.
  # Assumes there aren't any ';' in the branch names.
  STRING(REGEX REPLACE "\n" ";" ALL_BRANCHES "${ALL_BRANCHES}")
  # Find all remote release branches.
  # We ignore the local ones.
  set(RELEASE_BRANCHES ${ALL_BRANCHES})
  list(FILTER RELEASE_BRANCHES INCLUDE REGEX "/release-v[0-9]+\\.[0-9]")
  list(SORT RELEASE_BRANCHES COMPARE NATURAL ORDER DESCENDING)
  list(LENGTH RELEASE_BRANCHES BRANCHES_LENGTH)
  if (NOT ${BRANCHES_LENGTH} EQUAL 0)
    # The first branch is the latest version (by virtue of sorting in natural descending order).
    list(GET RELEASE_BRANCHES 0 NEWEST_BRANCH)
    string(REGEX MATCH "/release-v([0-9]+)\\.([0-9]+)" IGNORED "${NEWEST_BRANCH}")
    set(branch_major ${CMAKE_MATCH_1})
    set(branch_minor ${CMAKE_MATCH_2})
  endif()

  # If we are the child of a release-branch, use it, or a tag. Whichever is higher.
  # If we aren't a child of a release-branch, use the highest branch or tag.
  foreach (RELEASE_BRANCH ${RELEASE_BRANCHES})
    execute_process(
      COMMAND ${GIT_EXECUTABLE} merge-base --is-ancestor ${RELEASE_BRANCH} HEAD
      RESULT_VARIABLE RESULT
    )
    if (NOT "${RESULT}" EQUAL 0)
      continue()
    endif()
    # This branch is a child branch of a release-branch.
    string(REGEX MATCH "/release-v([0-9]+)\\.([0-9]+)" IGNORED "${RELEASE_BRANCH}")
    set(branch_major ${CMAKE_MATCH_1})
    set(branch_minor ${CMAKE_MATCH_2})
    if (${branch_major} EQUAL ${major} AND ${branch_minor} EQUAL ${minor})
      # There is already a release on this branch.
      # Use next patch version.
      MATH(EXPR patch "${patch}+1")
      set(${VERSION} "v${major}.${minor}.${patch}-pre.${CURRENT_COMMIT_NO}+${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
      return()
    endif()
    # First release on this major.minor branch.
    set(major ${branch_major})
    set(minor ${branch_minor})
    set(patch "0")
    # Instead of counting since the last tag, we count the commits that have been done in this branch.
    # Note that we are assuming that the default branch is called "master".
    backtick(COMMON_ANCESTOR ${GIT_EXECUTABLE} merge-base HEAD "origin/master")
    backtick(COMMITS_IN_BRANCH ${GIT_EXECUTABLE} rev-list --count "HEAD...${COMMON_ANCESTOR}")
    set(${VERSION} "v${major}.${minor}.${patch}-pre.${COMMITS_IN_BRANCH}+${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
    return()
  endforeach()

  # If we are on master/main or a checkout without a branch-name use the next highest release.
  if ("${CURRENT_BRANCH}" STREQUAL master OR "${CURRENT_BRANCH}" STREQUAL main OR "${CURRENT_BRANCH}" STREQUAL HEAD)
    # Master branch: v0.5.0-pre.17+9a1fbdb29
    set(BRANCH_ID "")
  else()
    # Other branch: v0.5.0-pre.17+branch-name.9a1fbd29
    # Semver requires the dot-separated identifiers to comprise only alphanumerics and hyphens.
    string(REGEX REPLACE "[^.0-9A-Za-z-]" "-" SANITIZED_BRANCH ${CURRENT_BRANCH})
    set(BRANCH_ID "${SANITIZED_BRANCH}.")
  endif()

  # Use either the latest reachable tag, or the highest branch. Whichever is higher.
  if ("${branch_major}.${branch_minor}" VERSION_GREATER "${major}.${minor}")
    set(major ${branch_major})
    set(minor ${branch_minor})
    # Update the commit number. Count the commits since the latest branch.
    backtick(COMMON_ANCESTOR ${GIT_EXECUTABLE} merge-base HEAD "${NEWEST_BRANCH}")
    backtick(COMMITS_SINCE_BRANCH ${GIT_EXECUTABLE} rev-list --count "HEAD...${COMMON_ANCESTOR}")
    # We need to ensure that later commits have higher versions.
    # However, once the branch is released, there will be a tag, and we will count the number
    # of commits from there. This could lead to newer commits having a shorter commit-count.
    # To ensure that the order stays correct we use a different pre-version identifier that is
    # always lower than the default identifier.
    set(pre_identifier "pr")
    MATH(EXPR minor "${minor}+1")
    set(${VERSION} "v${major}.${minor}.0-${pre_identifier}.${COMMITS_SINCE_BRANCH}+${BRANCH_ID}${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
    return()
  endif()
  MATH(EXPR minor "${minor}+1")
  set(${VERSION} "v${major}.${minor}.0-pre.${CURRENT_COMMIT_NO}+${BRANCH_ID}${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
endfunction()

# Print the git-version on stdout:
# cmake -DPRINT_VERSION=1 -P tools/gitversion.cmake
if (DEFINED PRINT_VERSION)
  compute_git_version(VERSION)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${VERSION}")
endif()
