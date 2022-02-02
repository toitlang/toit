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

# Computes a version from git branches and git tags.
# If a commit is tagged explicitly with a version tag (v1.2.3) then use that one.
# If a commit is on a release-branch (release-v1.2), then we have two cases:
#   - there is already a release on this branch (visible by a version tag with the
#     same major/minor)
#   - there isn't a release yet.
# If there is already a release, then count the commits since that release, and
#   mark the current commit as a prerelease of a patch-release. For example,
#   if we are on release-v1.2 and there is a tag v1.2.4. Then we count the commits
#   since that tag (say 5) and return 'v1.2.5-pre.5+<commit-hash>'
# If there isn't a release yet (no tag), then we count the commits since the previous
#   release-branch (say 38 commits since release-v1.1 branch point) and
#   return 'v1.2.0-pre.38+<commit-hash>'. We need to count from the previous branch-point
#   since 'master' is using the same naming scheme, and we need to ensure monotonically
#   increasing version numbers. (See next case).
# If a commit is not on a release-branch, find the newest release-branch (say release-v1.5),
#   and count the commits since it (say 22).
#   Return v1.6.0-pre.22+<commit-hash> if we are on master/main or don't know the branch name.
#   Return v1.6.0-pre.22+<branch-name>.<commit-hash> if we know the name.
# Note that "v1.6.0-pre." is also used on a release-v1.6 branch until the release has
#   happened. Care must be taken to ensure that the version numbers increase correctly.
function(compute_git_version VERSION)
  # Check that we are in a git tree.
  backtick(ignored ${GIT_EXECUTABLE} rev-parse --is-inside-work-tree)

  backtick(CURRENT_COMMIT ${GIT_EXECUTABLE} rev-parse HEAD)
  backtick(CURRENT_COMMIT_SHORT ${GIT_EXECUTABLE} rev-parse --short HEAD)

  # We assume that there is always a version-branch and a version tag.
  # We don't handle the initial case where no version branch is found.

  # Note: the clone of the repository must have access to all tags.
  # Buildbots might provide a shallow copy, in which case `git fetch --tags` must be called.

  backtick(TAG_COMMIT ${GIT_EXECUTABLE} rev-list --tags --max-count=1)
  # The '--abbrev=0' ensures that we only get the tag, without the number of intermediate commits.
  # The buildbot has a shallow checkout of our repository. We need to pass in the commit of the latest tag.
  # (Tbh not sure why.)
  backtick(LATEST_VERSION_TAG ${GIT_EXECUTABLE} describe --tags --match "v[0-9]*" --abbrev=0 ${TAG_COMMIT})
  set(SEMVER_REGEX "^v([0-9]+)\\.([0-9]+)\\.([0-9]+)")
  string(REGEX REPLACE ${SEMVER_REGEX} "\\1" tag_major ${LATEST_VERSION_TAG})
  string(REGEX REPLACE ${SEMVER_REGEX} "\\2" tag_minor ${LATEST_VERSION_TAG})
  string(REGEX REPLACE ${SEMVER_REGEX} "\\3" tag_patch ${LATEST_VERSION_TAG})

  backtick(VERSION_TAG_COMMIT ${GIT_EXECUTABLE} rev-parse "${LATEST_VERSION_TAG}^{}")

  # If we are directly on a version-tag commit, just use that one.
  if ("${VERSION_TAG_COMMIT}" STREQUAL "${CURRENT_COMMIT}")
    set(${VERSION} "${LATEST_VERSION_TAG}" PARENT_SCOPE)
    return()
  endif()

  # Find all release branches.
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
  if (${BRANCHES_LENGTH} EQUAL 0)
    message(FATAL_ERROR "No release branch found")
  endif()

  function (version_from_branch BRANCH MAJOR MINOR)
    string(REGEX MATCH "/release-v([0-9]+)\\.([0-9]+)" IGNORED "${BRANCH}")
    set(${MAJOR} "${CMAKE_MATCH_1}" PARENT_SCOPE)
    set(${MINOR} "${CMAKE_MATCH_2}" PARENT_SCOPE)
  endfunction()

  # Returns the distance of HEAD to the common ancestor of HEAD and COMMIT.
  function (commits_since_common_ancestor COMMIT COMMIT_COUNT)
    set(DEPTH 128)
    while (1)
      execute_process(
        COMMAND ${GIT_EXECUTABLE} merge-base HEAD "${COMMIT}"
        RESULT_VARIABLE result
        OUTPUT_VARIABLE COMMON_ANCESTOR
        OUTPUT_STRIP_TRAILING_WHITESPACE
      )
      if ("${result}" EQUAL 0)
        break()
      endif()
      if (${DEPTH} GREATER 10000)
        message(FATAL_ERROR "Couldn't determine merge-base for HEAD and ${COMMIT}")
      endif()
      backtick(ignored ${GIT_EXECUTABLE} fetch --depth=${DEPTH})
      math(EXPR DEPTH "${DEPTH} * 2")
    endwhile()
    backtick(COMMITS_IN_BRANCH ${GIT_EXECUTABLE} rev-list --count "HEAD...${COMMON_ANCESTOR}")
    set(${COMMIT_COUNT} ${COMMITS_IN_BRANCH} PARENT_SCOPE)
  endfunction()

  # Run through the release-branches to see if we are on one.
  math(EXPR LEN_MINUS_1 "${BRANCHES_LENGTH} - 1")
  foreach (index RANGE ${LEN_MINUS_1})
    list(GET RELEASE_BRANCHES ${index} RELEASE_BRANCH)
    execute_process(
      COMMAND ${GIT_EXECUTABLE} merge-base --is-ancestor ${RELEASE_BRANCH} HEAD
      RESULT_VARIABLE RESULT
    )
    if (NOT "${RESULT}" EQUAL 0)
      continue()
    endif()
    # This commit is a child branch of a release-branch.
    version_from_branch("${RELEASE_BRANCH}" branch_major branch_minor)
    if (${branch_major} EQUAL ${tag_major} AND ${branch_minor} EQUAL ${tag_minor})
      # There is already a release on this branch.
      # Use next patch version.
      MATH(EXPR patch "${tag_patch}+1")
      # Count the distance to the last tag.
      backtick(CURRENT_COMMIT_NO ${GIT_EXECUTABLE} rev-list --count HEAD "^${VERSION_TAG_COMMIT}")
      set(${VERSION} "v${tag_major}.${tag_minor}.${patch}-pre.${CURRENT_COMMIT_NO}+${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
      return()
    endif()
    # First release on this major.minor branch.

    # We need to find the distance to the previous commit-branch to maintain a consistent
    # counting (monotonically increasing).
    # We assume the next release-branch in the list is the previous branch-point.
    # Remember: the release-branches are sorted in descending order.
    math(EXPR next_index "${index}+1")
    list(GET RELEASE_BRANCHES ${next_index} PREVIOUS_RELEASE_BRANCH)
    commits_since_common_ancestor(${PREVIOUS_RELEASE_BRANCH} COMMITS_SINCE_LAST_RELEASE)
    set(${VERSION} "v${branch_major}.${branch_minor}.0-pre.${COMMITS_SINCE_LAST_RELEASE}+${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
    return()
  endforeach()

  # We are not on a release branch.
  # Use the next highest release since the last release branch.

  # The first branch is the latest version (by virtue of sorting in natural descending order).
  list(GET RELEASE_BRANCHES 0 NEWEST_BRANCH)
  version_from_branch("${NEWEST_BRANCH}" branch_major branch_minor)
  # Count the commits since the last release-branch.
  commits_since_common_ancestor(${NEWEST_BRANCH} COMMITS_SINCE_LAST_RELEASE)

  backtick(CURRENT_BRANCH ${GIT_EXECUTABLE} rev-parse --abbrev-ref HEAD)
  if ("${CURRENT_BRANCH}" STREQUAL master OR "${CURRENT_BRANCH}" STREQUAL main OR "${CURRENT_BRANCH}" STREQUAL HEAD)
    # Master branch: v0.5.0-pre.17+9a1fbdb29
    set(BRANCH_ID "")
  else()
    # Other branch: v0.5.0-pre.17+branch-name.9a1fbd29
    # Semver requires the dot-separated identifiers to comprise only alphanumerics and hyphens.
    string(REGEX REPLACE "[^.0-9A-Za-z-]" "-" SANITIZED_BRANCH ${CURRENT_BRANCH})
    set(BRANCH_ID "${SANITIZED_BRANCH}.")
  endif()

  MATH(EXPR minor "${branch_minor}+1")
  set(${VERSION} "v${branch_major}.${minor}.0-pre.${COMMITS_SINCE_LAST_RELEASE}+${BRANCH_ID}${CURRENT_COMMIT_SHORT}" PARENT_SCOPE)
endfunction()

# Print the git-version on stdout:
# cmake -DPRINT_VERSION=1 -P tools/gitversion.cmake
if (DEFINED PRINT_VERSION)
  compute_git_version(VERSION)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${VERSION}")
endif()
