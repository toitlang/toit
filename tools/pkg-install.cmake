cmake_minimum_required(VERSION 3.12)

# Default values for customizable paths.
set(PACKAGE_LOCK_PATH "package.lock" CACHE FILEPATH "Path to the package.lock file.")
set(PACKAGES_DIR ".packages" CACHE PATH "Directory to store cloned packages.")
set(QUIET FALSE CACHE BOOL "Suppress output.")

if (QUIET)
  # Run this script again but with OUTPUT_QUIET set.
  # Since this is a recursive call, we set the QUIET to false now.
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
      "-DPACKAGE_LOCK_PATH=${PACKAGE_LOCK_PATH}"
      "-DPACKAGES_DIR=${PACKAGES_DIR}"
      "-DQUIET=FALSE"
      -P "${CMAKE_CURRENT_LIST_FILE}"
    OUTPUT_QUIET
    COMMAND_ERROR_IS_FATAL ANY
  )
  return()
endif()

# Find Git.
find_package(Git REQUIRED)

# Function to clone a single repository.
function(clone_repo url version hash)
  # Determine the full path for the packages directory.
  get_filename_component(package_lock_dir "${PACKAGE_LOCK_PATH}" ABSOLUTE)
  get_filename_component(package_lock_dir "${package_lock_dir}" DIRECTORY)

  if(IS_ABSOLUTE "${PACKAGES_DIR}")
    set(packages_full_path "${PACKAGES_DIR}")
  else()
    set(packages_full_path "${package_lock_dir}/${PACKAGES_DIR}")
  endif()

  set(repo_dir "${packages_full_path}/${url}/${version}")

  if(NOT EXISTS "${repo_dir}")
    message(STATUS "Cloning ${url} version ${version}")
    execute_process(
      COMMAND "${GIT_EXECUTABLE}" clone "https://${url}" "${repo_dir}"
      RESULT_VARIABLE git_result
    )
    if(NOT git_result EQUAL "0")
      message(FATAL_ERROR "Failed to clone ${url}")
    endif()

    execute_process(
      COMMAND "${GIT_EXECUTABLE}" -C "${repo_dir}" checkout -q "${hash}"
      RESULT_VARIABLE git_result
    )
    if(NOT git_result EQUAL "0")
      message(FATAL_ERROR "Failed to checkout ${hash} for ${url}")
    endif()
    file(REMOVE_RECURSE "${repo_dir}/.git")
  else()
    message(STATUS "Repository ${url} version ${version} already exists")
  endif()
endfunction()

# Main script.
get_filename_component(PACKAGE_LOCK_PATH "${PACKAGE_LOCK_PATH}" ABSOLUTE)
if(NOT EXISTS "${PACKAGE_LOCK_PATH}")
  message(FATAL_ERROR "package.lock file not found at ${PACKAGE_LOCK_PATH}")
endif()

file(READ "${PACKAGE_LOCK_PATH}" yaml_content)

# Extract packages section.
# This regex does the following:
# 1. ^.*\npackages: - Matches everything up to and including the "packages:" line.
# 2. ([^\n]*\n([ \t]+[^\n]+\n)+) - Captures the packages section:
#    a. [^\n]*\n - Matches the rest of the "packages:" line.
#    b. ([ \t]+[^\n]+\n)+ - Matches one or more indented lines (package entries).
# 3. The \\1 in the replacement keeps only the captured packages section.
string(REGEX REPLACE "^.*\npackages:([^\n]*\n([ \t]+[^\n]+\n)+)" "\\1" packages_section "${yaml_content}")

# Split into lines.
string(REPLACE "\n" ";" lines "${packages_section}")

set(current_package "")
set(url "")
set(version "")
set(hash "")

foreach(line ${lines})
  # Check if this is a new package entry (two spaces indentation).
  if(line MATCHES "^  [^ ]")
    # Process the previous package if we have one.
    if(NOT "${current_package}" STREQUAL "" AND NOT "${url}" STREQUAL "" AND NOT "${version}" STREQUAL "" AND NOT "${hash}" STREQUAL "")
      clone_repo("${url}" "${version}" "${hash}")
    endif()

    # Reset variables for the new package.
    set(current_package "${line}")
    set(url "")
    set(version "")
    set(hash "")
  elseif(line MATCHES "^    url: (.+)$")
    set(url "${CMAKE_MATCH_1}")
  elseif(line MATCHES "^    version: (.+)$")
    set(version "${CMAKE_MATCH_1}")
  elseif(line MATCHES "^    hash: (.+)$")
    set(hash "${CMAKE_MATCH_1}")
  endif()
endforeach()

# Process the last package.
if(NOT "${current_package}" STREQUAL "" AND NOT "${url}" STREQUAL "" AND NOT "${version}" STREQUAL "" AND NOT "${hash}" STREQUAL "")
  clone_repo("${url}" "${version}" "${hash}")
endif()
