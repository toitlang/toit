// Copyright (C) 2020 Toitware ApS.
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

#include <limits.h>
#include <vector>
#include "third_party/nlohmann/json.hpp"

#include "filesystem_archive.h"

#include "diagnostic.h"
#include "list.h"
#include "tar.h"
#include "util.h"

#include "../flags.h"
#include "../utils.h"

namespace toit {
namespace compiler {

static const char* const META_PATH = "/<meta>";
static const char* const SDK_PATH_PATH = "/<sdk-path>";
static const char* const PACKAGE_CACHE_PATHS_PATH = "/<package-cache-paths>";
static const char* const CWD_PATH_PATH = "/<cwd>";
static const char* const COMPILER_INPUT_PATH = "/<compiler-input>";
static const char* const INFO_PATH = "/<info>";

void FilesystemArchive::initialize(Diagnostics* diagnostics) {
  if (is_initialized_) return;
  is_initialized_ = true;
  char current_working_dir[PATH_MAX];
  int current_working_dir_len = -1;
  auto code = untar(path_, [&](const char* name,
                               char* content,
                               int size) {
    if (name[0] != '/') {
      // Not an absolute file.
      // Assume it's relative to the current working directory.
      if (current_working_dir_len == -1) {
        // Lazily compute the current working dir.
        auto cwd_result = getcwd(current_working_dir, PATH_MAX);
        if (cwd_result != current_working_dir) {
          diagnostics->report_error("Couldn't read current working directory.");
          exit(1);
        }
        current_working_dir_len = strlen(current_working_dir);
      }
      PathBuilder builder(this);
      builder.join(current_working_dir, name);
      name = builder.strdup();
    }
    archive_files_[std::string(name)] = {
      .content = content,
      .size = size,
    };
  });
  switch (code) {
    case UntarCode::ok:
      break;
    case UntarCode::not_found:
      diagnostics->report_error("Couldn't find source-archive '%s'", path_);
      return;
    case UntarCode::not_ustar:
      diagnostics->report_error("Source-archive not in expected ustar format '%s'", path_);
      return;
    case UntarCode::other:
      diagnostics->report_error("Error loading source archive '%s'", path_);
      return;
  }

  auto sdk_path_probe = archive_files_.find(std::string(SDK_PATH_PATH));
  if (sdk_path_probe == archive_files_.end()) {
    diagnostics->report_error("Missing sdk-path file in '%s'", path_);
    return;
  }
  sdk_path_ = sdk_path_probe->second.content;

  auto package_cache_paths_probe = archive_files_.find(std::string(PACKAGE_CACHE_PATHS_PATH));
  if (package_cache_paths_probe == archive_files_.end()) {
    diagnostics->report_error("Missing package-cache-paths file in '%s'", path_);
    return;
  }
  package_cache_paths_ = string_split(package_cache_paths_probe->second.content, "\n");

  // Check whether the archive contains the SDK.
  // If there is a file with the same prefix, we consider it to be there.
  size_t sdk_path_len = strlen(sdk_path_);
  if (sdk_path_len == 0) {
    // This should never happen.
    // If the sdk-path file exists, but nothing is in it, we just assume that
    // the sdk is present. There might be errors later on because of the
    // empty path, though.
    contains_sdk_ = true;
  } else {
    int separator_offset = sdk_path_[sdk_path_len - 1] == '/' ? -1 : 0;
    for (auto& entry : archive_files_.underlying_map()) {
      if (strncmp(entry.first.c_str(), sdk_path_, sdk_path_len) == 0 &&
          entry.first.c_str()[sdk_path_len + separator_offset] == '/') {
        contains_sdk_ = true;
        break;
      }
    }
  }

  auto cwd_path_probe = archive_files_.find(std::string(CWD_PATH_PATH));
  if (cwd_path_probe == archive_files_.end()) {
    diagnostics->report_error("Missing cwd-path file in '%s'", path_);
    return;
  }
  cwd_path_ = cwd_path_probe->second.content;

  auto info_probe = archive_files_.find(std::string(INFO_PATH));
  if (info_probe == archive_files_.end()) {
    diagnostics->report_error("Missing info file in '%s'", path_);
    return;
  }
  const char* info = info_probe->second.content;
  if (strcmp(info, "toit/archive") != 0) {
    diagnostics->report_error("Not a toit-archive '%s'", path_);
    return;
  }

  if (Flags::archive_entry_path != null) {
    entry_path_ = Flags::archive_entry_path;
  } else {
    auto input_path_probe = archive_files_.find(std::string(COMPILER_INPUT_PATH));
    if (input_path_probe == archive_files_.end()) {
      diagnostics->report_error("Missing compiler-input file in '%s'", path_);
      return;
    }

    auto compiler_input = input_path_probe->second;
    if (compiler_input.content[0] == '[') {
      // Assume it's a list of json-encoded entry points.
      // This is the "new" format.
      auto entry_path_list = nlohmann::json::parse(compiler_input.content,
                                                  compiler_input.content + compiler_input.size,
                                                  null,
                                                  false);  // Don't throw.
      if (!entry_path_list.is_array() || entry_path_list.size() == 0) {
        goto bad_meta;
      }
      if (entry_path_list.size() != 1) {
        diagnostics->report_error("Entry point must be provided with '-Xarchive_entry_path' for this archive.");
      }
      if (!entry_path_list[0].is_string()) {
        goto bad_meta;
      }
      entry_path_ = strdup(entry_path_list[0].get<std::string>().c_str());
    } else {
      // This path is deprecated.
      entry_path_ = compiler_input.content;
    }
  }

  {
    auto meta_probe = archive_files_.find(std::string(META_PATH));
    if (meta_probe == archive_files_.end()) {
      diagnostics->report_error("Missing meta file in '%s'", path_);
      return;
    }
    auto entry = meta_probe->second;
    auto json = nlohmann::json::parse(entry.content, entry.content + entry.size,
                                      null,
                                      false);  // Don't throw.
    if (!json.is_object()) goto bad_meta;
    {
      auto meta_files = json["files"];
      auto meta_directory_lists = json["directories"];
      if (!meta_files.is_object()) goto bad_meta;
      if (!meta_directory_lists.is_object()) goto bad_meta;

      for (auto& meta_file : meta_files.items()) {
        auto name = meta_file.key();
        auto meta_data = meta_file.value();
        if (!meta_data.is_object()) goto bad_meta;
        {
          auto exists = meta_data["exists"];
          auto is_regular = meta_data["is_regular"];
          auto is_directory = meta_data["is_directory"];
          auto has_content = meta_data["has_content"];
          if (!exists.is_boolean()) goto bad_meta;
          if (!is_regular.is_boolean()) goto bad_meta;
          if (!is_directory.is_boolean()) goto bad_meta;
          if (!has_content.is_boolean()) goto bad_meta;
          path_infos_[std::string(name)] = {
            .exists = exists,
            .is_regular_file = static_cast<bool>(is_regular),
            .is_directory = static_cast<bool>(is_directory),
          };
        }
      }
      for (auto& entry : meta_directory_lists.items()) {
        auto name = entry.key();
        auto meta_list = entry.value();
        if (!meta_list.is_array()) goto bad_meta;
        {
          ListBuilder<std::string> builder;
          for (auto& entry : meta_list) {
            if (!entry.is_string()) goto bad_meta;
            builder.add(entry.get<std::string>());
          }
          directory_listings_[name] = builder.build();
        }
      }
    }
  }
  return;

  bad_meta:
    diagnostics->report_error("Bad meta file format in '%s'", path_);
    return;
}

bool FilesystemArchive::do_exists(const char* path) {
  auto info_probe = path_infos_.find(std::string(path));
  if (info_probe == path_infos_.end()) return false;
  return info_probe->second.exists;
}

bool FilesystemArchive::do_is_regular_file(const char* path) {
  auto info_probe = path_infos_.find(std::string(path));
  if (info_probe == path_infos_.end()) return false;
  return info_probe->second.is_regular_file;
}

bool FilesystemArchive::do_is_directory(const char* path) {
  auto info_probe = path_infos_.find(std::string(path));
  if (info_probe == path_infos_.end()) return false;
  return info_probe->second.is_directory;
}

const uint8* FilesystemArchive::do_read_content(const char* path, int* size) {
  auto probe = archive_files_.find(path);
  if (probe != archive_files_.end()) {
    auto entry = probe->second;
    *size = entry.size;
    return unsigned_cast(entry.content);
  }
  return unsigned_cast("");
}

void FilesystemArchive::list_directory_entries(const char* path,
                                               const std::function<void (const char*)> callback) {
  auto probe = directory_listings_.find(std::string(path));
  if (probe == directory_listings_.end()) return;
  for (auto& entry : probe->second) {
    callback(entry.c_str());
  }
}

bool FilesystemArchive::is_probably_archive(const char* path) {
  return is_tar_file(path);
}

} // namespace compiler
} // namespace toit
