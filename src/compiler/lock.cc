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

#include <string>
#include <limits.h>

#include "third_party/libyaml/include/yaml.h"
#include "third_party/nlohmann/json.hpp"
#include "third_party/semver/semver.h"

#include "../top.h"

#include "filesystem_local.h"
#include "lock.h"
#include "scanner.h"
#include "sources.h"
#include "util.h"


namespace toit {
namespace compiler {

static const char* LOCK_FILE = "package.lock";
static const char* CONTENTS_FILE = "contents.json";
static const char* PACKAGE_CACHE_PATH = ".cache/toit/tpkg/";
static const char* LOCAL_PACKAGE_DIR = ".packages";

// The label for the prefixes in the lockfile.
static const char* PREFIXES_LABEL = "prefixes";
// The label for the packages in the lockfile.
static const char* PACKAGES_LABEL = "packages";
// The label for SDK entry in the lockfile.
static const char* SDK_LABEL = "sdk";
// The label for path entries in the lockfile.
static const char* PATH_LABEL = "path";
// The label for name entries in the lockfile.
static const char* NAME_LABEL = "name";

// The directory in which packages have their sources.
static constexpr const char* PACKAGE_SOURCE_DIR = "src";


const char* compute_package_cache_path_from_home(const char* home, Filesystem* fs) {
  PathBuilder builder(fs);
  builder.join(home);
  builder.join(PACKAGE_CACHE_PATH);
  return builder.strdup();
}



Package PackageLock::resolve_prefix(const Package& package,
                                    const std::string& prefix) const {
  auto prefix_probe = package.prefixes_.find(prefix);
  if (prefix_probe != package.prefixes_.end()) {
    auto prefix_id = prefix_probe->second;
    auto pkg_probe = packages_.find(prefix_id);
    if (pkg_probe == packages_.end()) {
      // The prefix points to a package-id that is in the lock file, but we
      // weren't able to find the actual package.
      return packages_.at(Package::ERROR_PACKAGE_ID);
    }
    return pkg_probe->second;
  }
  // No prefix mapping for this package-id.
  // Assume it's for the SDK.
  if (sdk_prefixes_.contains(prefix)) {
    return packages_.at(Package::SDK_PACKAGE_ID);
  }
  return Package::invalid();
}

Package PackageLock::package_for(const std::string& path, Filesystem* fs) const {
  if (SourceManager::is_virtual_file(path.c_str())) {
    return packages_.at(Package::VIRTUAL_PACKAGE_ID);
  }

  // Paths that come in here must be absolute.
  ASSERT(fs->is_absolute(path.c_str()));
  auto cache_probe = path_to_package_cache_.find(path);
  if (cache_probe != path_to_package_cache_.end()) {
    return packages_.at(cache_probe->second);
  }
  std::vector<std::string> to_cache;
  for (int i = path.size() - 1; i >= 0; i--) {
    if (fs->is_path_separator(path[i])) {
      auto sub = path.substr(0, i);
      auto probe = path_to_package_cache_.find(sub);
      if (probe != path_to_package_cache_.end()) {
        path_to_package_cache_[path] = probe->second;
        for (auto p : to_cache) {
          path_to_package_cache_[p] = probe->second;
        }
        return packages_.at(probe->second);
      }
      to_cache.push_back(sub);
    }
  }
  // Any file that isn't nested in a package path is assumed to be in the
  // entry-package. This allows applications (but not packages) to dot out as
  // much as they want.
  // It also simplifies handling of package.lock files that aren't stored at
  // the root of a project.
  return packages_.at(Package::ENTRY_PACKAGE_ID);
}

// Searches for the lock file in the given directory.
std::string find_lock_file_at(const char* dir,
                              Filesystem* fs) {
  if (SourceManager::is_virtual_file(dir)) return "";

  PathBuilder builder(fs);
  if (!fs->is_absolute(dir)) {
    builder.join(fs->relative_anchor(dir));
  }
  builder.join(dir);
  builder.join(LOCK_FILE);
  builder.canonicalize();
  if (fs->exists(builder.c_str())) {
    return builder.buffer();
  }
  return "";
}

// Searches for the lock file starting at [source_path].
std::string find_lock_file(const char* source_path,
                           Filesystem* fs) {
  if (SourceManager::is_virtual_file(source_path)) return "";

  PathBuilder builder(fs);
  if (!fs->is_absolute(source_path)) {
    builder.join(fs->relative_anchor(source_path));
  }
  builder.join(source_path);
  // Drop the filename.
  builder.join("..");
  builder.canonicalize();

  // Add a trailing '/', so we can unify the loop.
  builder.add(fs->path_separator());

  for (int i = builder.length() - 1; i >= 0; i--) {
    if (fs->is_path_separator(builder[i])) {
      builder.reset_to(i + 1);
      builder.join(LOCK_FILE);
      if (fs->exists(builder.c_str())) {
        return builder.buffer();
      }
    }
  }
  return "";
}

static std::string build_canonical_sdk_dir(Filesystem* fs) {
  const char* sdk_lib_dir = fs->library_root();
  PathBuilder sdk_builder(fs);
  if (!fs->is_absolute(sdk_lib_dir)) {
    sdk_builder.join(fs->relative_anchor(sdk_lib_dir));
  }
  sdk_builder.join(sdk_lib_dir);
  sdk_builder.canonicalize();
  return sdk_builder.buffer();
}

void PackageLock::list_sdk_prefixes(const std::function<void (const std::string& candidate)>& callback) const {
  for (auto sdk_prefix : sdk_prefixes_) {
    callback(sdk_prefix);
  }
}

PackageLock::PackageLock(Source* lock_source,
                         const std::string& sdk_constraint,
                         const Map<std::string, Package>& packages,
                         const Set<std::string>& sdk_prefixes,
                         bool has_errors)
    : lock_file_source_(lock_source)
    , has_errors_(has_errors)
    , sdk_prefixes_(sdk_prefixes)
    , packages_(packages)
    , sdk_constraint_(sdk_constraint) {
  for (auto id : packages.keys()) {
    auto package = packages.at(id);
    if (!package.has_valid_path()) continue;
    path_to_package_cache_[package.absolute_path()] = id;
  }
}

namespace {  // Anonymous.
  struct Entry {
    std::string url;
    std::string version;
    std::string path;
    std::string name;
    Source::Range range;
  };

  struct LockFileContent {
    Source* source;
    // A mapping from package-ids to their prefixes (which maps from prefix to package-id).
    Map<std::string, Entry> packages;
    Map<std::string, Map<std::string, std::string>> prefixes;
    std::string sdk_constraint;
    bool has_errors;

    static LockFileContent empty(Source* source = null) {
      return {
        .source = source,
        .packages = {},
        .prefixes = {},
        .sdk_constraint = "",
        .has_errors = false,
      };
    }
  };
}

static bool is_valid_package_id(const std::string& package_id) {
  // For now just make it simple and only check that id resembles a
  // valid identifier.
  // We don't check that the start isn't a number, and we also allow '+', '-', '*', '/' and '.'.
  if (package_id.empty()) return false;
  for (size_t i = 0; i < package_id.size(); i++) {
    char c = package_id[i];
    if (is_letter(c) || is_decimal_digit(c)) continue;
    if (c == '_' || c == '+' || c == '-' || c == '*' || c == '/' || c == '\\' || c == '.') continue;
    return false;
  }
  return true;
}

static bool is_valid_prefix(const std::string& prefix) {
  if (prefix.empty()) return false;
  IdentifierValidator validator;

  for (size_t i = 0; i < prefix.size(); i++) {
    if (!validator.check_next_char(prefix[i], [&]() { return prefix[i + 1]; })) {
      return false;
    }
  }
  return true;
}

namespace {  // Anonymous namespace.

class YamlParser {
 public:
  enum Status {
    OK,
    UNEXPECTED,
    FATAL,
  };

  YamlParser(Source* source, Diagnostics* diagnostics);
  ~YamlParser();

  // Skips to the beginning of the body.
  // Must be called at the beginning of the parsing.
  Status skip_to_body();

  Status parse_map(const std::function<Status (const std::string& key,
                                               const Source::Range& range)>& callback);

  Status parse_string(const std::function<Status (const std::string& str,
                                                  const Source::Range& range)>& callback);

  // Consumes tokens until the next call to 'peek' returns a new element.
  // For example, if the current element is a scalar, then no call to next is done.
  // However, if it's the start of a list, then all nested elements are consumed and
  // the function returns when 'peek' returns the token after the list-end event.
  // Returns 'OK', or 'PARSER_ERROR'.
  Status skip();

  // Whether we are at the end of the file.
  // This function may only be called after 'skip_to_body'.
  bool is_at_end() const;

 private:
  Source* source_;
  Diagnostics* diagnostics_;
  yaml_parser_t parser_;
  yaml_event_t event_;
  bool needs_freeing_ = false;

  yaml_event_t peek() {
    ASSERT(needs_freeing_);
    return event_;
  }
  Status next();

  void report_unexpected(const char* expected);
  void report_parse_error();
};

}

YamlParser::YamlParser(Source* source, Diagnostics* diagnostics)
  : source_(source), diagnostics_(diagnostics) {
  yaml_parser_initialize(&parser_);
  auto ucontent = reinterpret_cast<const unsigned char*>(source->text());
  yaml_parser_set_input_string(&parser_, ucontent, source->size());
}

YamlParser::~YamlParser() {
  if (needs_freeing_) {
    yaml_event_delete(&event_);
  }
  yaml_parser_delete(&parser_);
}

YamlParser::Status YamlParser::skip_to_body() {
  auto status = next();
  if (status != OK) return status;
  if (event_.type != YAML_STREAM_START_EVENT) {
    report_parse_error();
    return FATAL;
  }
  status = next();
  if (status != OK) return status;
  // Empty files don't have a body. We are ok with that.
  if (event_.type == YAML_STREAM_END_EVENT) return OK;
  if (event_.type != YAML_DOCUMENT_START_EVENT) {
    report_parse_error();
    return FATAL;
  }
  return next();
}

bool YamlParser::is_at_end() const {
  return event_.type == YAML_STREAM_END_EVENT || event_.type == YAML_DOCUMENT_END_EVENT;
}

YamlParser::Status YamlParser::parse_map(const std::function<YamlParser::Status (const std::string& key,
                                                                                 const Source::Range& range)>& callback) {
  if (peek().type != YAML_MAPPING_START_EVENT) {
    report_unexpected("map");
    auto status = skip();
    if (status != OK) return status;
    return UNEXPECTED;
  }
  auto status = next();
  if (status != OK) return status;

  while (peek().type != YAML_MAPPING_END_EVENT) {
    auto event = peek();
    if (event.type != YAML_SCALAR_EVENT) {
      // This should be the key of the mapping.
      report_unexpected("string");
      return FATAL;
    }
    auto status = parse_string(callback);
    // We survive non-fatal errors.
    if (status == FATAL) return status;
    event = peek();
  }
  return next();
}

YamlParser::Status YamlParser::parse_string(const std::function<YamlParser::Status (const std::string& str,
                                                                                    const Source::Range& range)>& callback) {
  auto event = peek();
  if (event.type != YAML_SCALAR_EVENT) {
    report_unexpected("string");
    auto status = skip();
    if (status != OK) return status;
    return UNEXPECTED;
  }
  // TODO(florian): check whether we need to read 'event.data.scalar.style'.
  unsigned char* scalar_str = event.data.scalar.value;
  std::string str(char_cast(scalar_str));
  auto range = source_->range(event.start_mark.index, event.end_mark.index);
  auto status = next();
  if (status != OK) return status;
  return callback(str, range);
}

YamlParser::Status YamlParser::next() {
  if (needs_freeing_) {
    yaml_event_delete(&event_);
    needs_freeing_ = false;
  }
  if (!yaml_parser_parse(&parser_, &event_)) {
    report_parse_error();
    return FATAL;
  }
  needs_freeing_ = true;
  if (event_.type == YAML_NO_EVENT) {
    FATAL("shouldn't get a no-event");
  }
  return OK;
}

YamlParser::Status YamlParser::skip() {
  switch (peek().type) {
    case YAML_NO_EVENT:
      // Not sure this can even happen.
      return OK;

    case YAML_STREAM_START_EVENT:
    case YAML_DOCUMENT_START_EVENT:
    case YAML_SEQUENCE_START_EVENT:
    case YAML_MAPPING_START_EVENT:
      break;

    case YAML_STREAM_END_EVENT:
    case YAML_DOCUMENT_END_EVENT:
    case YAML_SEQUENCE_END_EVENT:
    case YAML_MAPPING_END_EVENT:
      // This could may happen if we expected a specific element, but nothing was there.
      return OK;

    case YAML_ALIAS_EVENT:
    case YAML_SCALAR_EVENT:
      return next();
  }

  // Consume the 'start' event.
  auto status = next();
  if (status != OK) return status;

  // If we are here, then we need to wait for the end-event.
  while (true) {
    switch (peek().type) {
      // We are not checking whether the start and end event match. As soon as we
      // see an end-event we assume we finished the element.
      case YAML_STREAM_END_EVENT:
      case YAML_DOCUMENT_END_EVENT:
      case YAML_SEQUENCE_END_EVENT:
      case YAML_MAPPING_END_EVENT:
        // Done skipping.
        return next();

      default:
        // Recursively skip the
        auto status = skip();
        if (status != OK) return status;
        break;
    }
  }
}

void YamlParser::report_parse_error() {
  auto error_range = source_->range(parser_.problem_mark.index, parser_.problem_mark.index);
  auto message = parser_.problem;
  diagnostics_->report_error(error_range, "Couldn't parse package lock file: %s", message);
}

static const char* type_to_string(yaml_event_type_t type) {
  switch (type) {
    case YAML_STREAM_START_EVENT:
    case YAML_DOCUMENT_START_EVENT:
    case YAML_NO_EVENT:
      // Should be unreachable.
      return "<error>";

    case YAML_SEQUENCE_START_EVENT:
    case YAML_SEQUENCE_END_EVENT:
      return "list";

    case YAML_MAPPING_START_EVENT:
    case YAML_MAPPING_END_EVENT:
      return "map";

    case YAML_STREAM_END_EVENT:
    case YAML_DOCUMENT_END_EVENT:
      return "eof";

    case YAML_ALIAS_EVENT:
      return "alias";

    case YAML_SCALAR_EVENT:
      return "scalar";
  }
  return "";
}

void YamlParser::report_unexpected(const char* expected_type) {

  auto error_range(source_->range(event_.start_mark.index, event_.end_mark.index));
  auto actual = type_to_string(event_.type);
  diagnostics_->report_error(error_range,
                             "Invalid package lock file. Expected a %s, got a%s %s",
                             expected_type,
                             actual[0] == 'a' || actual[0] == '<' || actual[0] == 'e' ? "n" : "",
                             actual);
}

static LockFileContent parse_lock_file(const std::string& lock_file_path,
                                       SourceManager* source_manager,
                                       Diagnostics* diagnostics) {
  auto load_result = source_manager->load_file(lock_file_path, Package::invalid());
  if (load_result.status != SourceManager::LoadResult::OK) {
    load_result.report_error(diagnostics);
    auto result = LockFileContent::empty();
    result.has_errors = true;
    return result;
  }

  auto source = load_result.source;

  std::string ERROR_PACKAGE_ID(Package::ERROR_PACKAGE_ID);

  Set<std::string> existing_package_ids;
  {
    // We do a quick first pass just to find all existing package ids.
    NullDiagnostics null_diag(source_manager);
    YamlParser parser(source, &null_diag);
    auto status = parser.skip_to_body();
    if (status == YamlParser::OK && !parser.is_at_end()) {
      parser.parse_map([&](const std::string& key, const Source::Range& _) {
        if (key != PACKAGES_LABEL) {
          return parser.skip();
        }
        return parser.parse_map([&](const std::string& pkg_id, const Source::Range& _) {
          existing_package_ids.insert(pkg_id);
          return parser.skip();
        });
      });
    }
  }

  YamlParser parser(source, diagnostics);

  auto status = parser.skip_to_body();
  if (status != YamlParser::OK) {
    auto result = LockFileContent::empty(source);
    result.has_errors = true;
    return result;
  } else if (parser.is_at_end()) {
    return LockFileContent::empty(source);
  }

  bool has_errors = false;
  bool packages_seen = false;
  bool prefixes_seen = false;
  bool sdk_seen = false;

  Map<std::string, Map<std::string, std::string>> prefixes;
  Map<std::string, Entry> packages;
  std::string sdk_constraint;

  auto parse_prefixes = [&](const std::string& owner) {
    Map<std::string, std::string> pkg_prefixes;

    auto status = parser.parse_map([&](const std::string& prefix, const Source::Range& prefix_range) {
      auto prefix_probe = pkg_prefixes.find(prefix);
      if (prefix_probe != pkg_prefixes.end()) {
        diagnostics->report_error(prefix_range,
                                  "Prefix '%s' is declared multiple times",
                                  prefix.c_str());
        has_errors = true;
      }

      if (!is_valid_prefix(prefix)) {
        diagnostics->report_error(prefix_range,
                                  "Invalid prefix '%s'",
                                  prefix.c_str());
        has_errors = true;
      }

      auto canonicalized = IdentifierValidator::canonicalize(prefix);

      std::string target_id;
      auto target_range = Source::Range::invalid();
      auto status = parser.parse_string([&](const std::string& str, const Source::Range& range) {
        target_id = str;
        target_range = range;
        return YamlParser::OK;
      });
      if (status != YamlParser::OK) {
        has_errors = true;
        target_id = ERROR_PACKAGE_ID;
      } else if (!is_valid_package_id(target_id)) {
        has_errors = true;
        diagnostics->report_error(target_range, "Invalid package id: '%s'", target_id.c_str());
        target_id = ERROR_PACKAGE_ID;
      } else if (!existing_package_ids.contains(target_id)) {
        has_errors = true;
        diagnostics->report_error(target_range,
                                  "Package '%s', target of prefix '%s', not found",
                                  target_id.c_str(),
                                  canonicalized.c_str());
        target_id = Package::ERROR_PACKAGE_ID;
      }

      pkg_prefixes[canonicalized] = target_id;
      return YamlParser::OK;
    });

    prefixes[owner] = pkg_prefixes;
    return status;
  };

  auto parse_packages = [&]() {
    return parser.parse_map([&](const std::string& pkg_id, const Source::Range& pkg_id_range) {
      if (!is_valid_package_id(pkg_id)) {
        diagnostics->report_error(pkg_id_range,
                                  "Invalid package id: '%s'",
                                  pkg_id.c_str());
        has_errors = true;
      }
      auto pkg_probe = packages.find(pkg_id);
      if (pkg_probe != packages.end()) {
        diagnostics->report_error(pkg_id_range,
                                  "Package id '%s' has multiple entries",
                                  pkg_id.c_str());
        has_errors = true;
      }

      std::string url;
      bool seen_url = false;

      std::string version;
      bool seen_version = false;

      std::string path;
      bool seen_path = false;

      std::string name;
      bool seen_name = false;

      bool seen_prefixes = false;

      bool is_valid = true;

      auto pkg_location_range = Source::Range::invalid();

      auto status = parser.parse_map([&](const std::string& key, const Source::Range& key_range) {
        if (key == "url") {
          if (seen_url) {
            diagnostics->report_error(key_range, "Multiple 'url' entries");
            has_errors = true;
          }
          seen_url = true;
          return parser.parse_string([&](const std::string& url_str, const Source::Range& url_range) {
            if (url_str == "") diagnostics->report_error(key_range, "URL must not be empty string");
            url = url_str;
            if (!pkg_location_range.is_valid()) {
              pkg_location_range = url_range;
            }
            return YamlParser::OK;
          });
        }

        if (key == "version") {
          if (seen_version) {
            diagnostics->report_error(key_range, "Multiple 'version' entries");
            has_errors = true;
          }
          seen_version = true;
          return parser.parse_string([&](const std::string& version_str, const Source::Range& version_range) {
            if (version_str == "") diagnostics->report_error(key_range, "Version must not be empty string");
            version = version_str;
            return YamlParser::OK;
          });
        }

        if (key == PATH_LABEL) {
          if (seen_path) {
            diagnostics->report_error(key_range, "Multiple 'path' entries");
            has_errors = true;
          }
          seen_path = true;
          return parser.parse_string([&](const std::string& path_str, const Source::Range& path_range) {
            if (path_str == "") {
              diagnostics->report_error(key_range, "Path must not be empty string");
              is_valid = false;
            }
            pkg_location_range = path_range;  // Path range wins over url-range.
            path = path_str;
            return YamlParser::OK;
          });
        }

        if (key == NAME_LABEL) {
          if (seen_name) {
            diagnostics->report_error(key_range, "Multiple 'name' entries");
            has_errors = true;
          }
          seen_name = true;
          return parser.parse_string([&](const std::string& name_str, const Source::Range& name_range) {
            if (name_str == "") {
              diagnostics->report_error(key_range, "Name must not be empty string");
              is_valid = false;
            }
            name = name_str;
            return YamlParser::OK;
          });
        }

        if (key == PREFIXES_LABEL) {
          if (seen_prefixes) {
            diagnostics->report_error(key_range, "Multiple 'prefixes' entries");
            has_errors = true;
          }
          seen_prefixes = true;
          return parse_prefixes(pkg_id);
        }

        return parser.skip();
      });

      if (seen_url) {
        if (!seen_version) {
          diagnostics->report_error(pkg_id_range, "Package '%s' has url, but no version", pkg_id.c_str());
          is_valid = false;
        }
      }
      if (seen_version && !seen_url) {
        diagnostics->report_warning(pkg_id_range, "Package '%s' has version, but no url", pkg_id.c_str());
      }
      if (!seen_url && !seen_path) {
        diagnostics->report_error(pkg_id_range, "Package '%s' is missing a 'url' or 'path' entry", pkg_id.c_str());
        is_valid = false;
      }
      // TODO(florian): add check that "name" must be present.
      // Older versions of the lock file didn't have the name field.

      if (!is_valid) has_errors = true;

      if (is_valid) {
        Entry entry = {
          .url = url,
          .version = version,
          .path = path,
          .name = name,
          .range = pkg_location_range,
        };
        packages.set(pkg_id, entry);
      }

      return status;
    });
  };

  status = parser.parse_map([&](const std::string& key, const Source::Range& range) {
    if (key == PREFIXES_LABEL) {
      if (prefixes_seen) {
        diagnostics->report_error(range, "Multiple 'prefixes' sections");
        has_errors = true;
      }
      prefixes_seen = true;
      // We will parse the prefixes and overwrite the original ones.
      return parse_prefixes(std::string(""));
    }
    if (key == PACKAGES_LABEL) {
      if (packages_seen) {
        diagnostics->report_error(range, "Multiple 'packages' sections");
        has_errors = true;
      }
      packages_seen = true;
      return parse_packages();
    }
    if (key == SDK_LABEL) {
      if (sdk_seen) {
        diagnostics->report_error(range, "Multiple 'sdk' sections");
        has_errors = true;
      }
      sdk_seen = true;
      return parser.parse_string([&](const std::string& str, const Source::Range& range) {
        if (str == "") {
          diagnostics->report_error(range, "Invalid empty SDK constraint");
        } else if (str[0] != '^') {
          diagnostics->report_error(range, "SDK constraint must be of form '^version': '%s'", str.c_str());
        } else {
          semver_t _;
          int semver_status = semver_parse(&str.c_str()[1], &_);
          if (semver_status != 0) {
            diagnostics->report_error(range, "Invalid SDK constraint: '%s'", str.c_str());
          } else {
            sdk_constraint = str;
          }
        }
        return YamlParser::OK;
      });
    }
    diagnostics->report_warning(range, "Unexpected entry in package.lock file: '%s'", key.c_str());
    return parser.skip();
  });

  if (status != YamlParser::OK) has_errors = true;

  return {
    .source = source,
    .packages = packages,
    .prefixes = prefixes,
    .sdk_constraint = sdk_constraint,
    .has_errors = has_errors,
  };
}

static void fill_package_mappings(Map<std::string, Map<std::string, std::string>>* mappings,
                                  List<const char*> package_dirs,
                                  Filesystem* fs) {
  for (auto package_dir : package_dirs) {
    PathBuilder path_builder(fs);
    path_builder.join(package_dir);
    path_builder.join(CONTENTS_FILE);
    auto mapping_path = path_builder.buffer();
    if (fs->exists(mapping_path.c_str())) {
      int source_size;
      auto mapping_source = fs->read_content(mapping_path.c_str(), &source_size);
      auto json = nlohmann::json::parse(mapping_source, mapping_source + source_size,
                                        null,
                                        false);  // Don't throw.
      if (json.is_discarded() || !json.is_object()) {
        // We couldn't parse the file.
        // TODO(florian): report error.
        continue;
      }
      for (auto& entry : json.items()) {
        auto key = entry.key();
        auto value = entry.value();
        if (!value.is_object()) {
          // We only support map values.
          // TODO(florian): report error.
          continue;
        }

        for (auto& version_entry : value.items()) {
          auto version = version_entry.key();
          auto value = version_entry.value();
          if (!value.is_string()) {
            // We only support string values.
            // TODO(florian): report error.
            continue;
          }
          PathBuilder package_path_builder(fs);
          package_path_builder.join(package_dir);
          package_path_builder.join(value.get<std::string>());
          auto& mapping = (*mappings)[key];
          if (mapping.find(version) == mapping.end()) {
            mapping.set(version, package_path_builder.buffer());
          }
        }
      }
    }
  }
}

PackageLock PackageLock::read(const std::string& lock_file_path,
                              const char* entry_path,
                              SourceManager* source_manager,
                              Filesystem* fs,
                              Diagnostics* diagnostics) {
  bool entry_is_absolute = fs->is_absolute(entry_path);
  LockFileContent lock_content;

  if (lock_file_path.empty()) {
    lock_content = LockFileContent::empty();
  } else {
    lock_content = parse_lock_file(lock_file_path, source_manager, diagnostics);
  }

  const Map<std::string, std::string> no_prefixes;
  Map<std::string, Package> packages;

  // We always have:
  // - the virtual package.
  // - the error package.
  // - the SDK package.
  // - the entry package.
  // After that we add the user-supplied packages.

  ASSERT(!is_valid_package_id(Package::VIRTUAL_PACKAGE_ID));
  Package virtual_package(Package::VIRTUAL_PACKAGE_ID,
                          Package::NO_NAME,
                          std::string(""),  // Doesn't matter. Should never be used.
                          std::string(""),  // Doesn't matter. Should never be used.
                          std::string(""),  // Doesn't matter. Should never be used.
                          Package::STATE_OK,
                          {},
                          false);  // Not a path package.
  // Note that the virtual package must not be added to the path-to-package map.
  packages[Package::VIRTUAL_PACKAGE_ID] = virtual_package;

  ASSERT(!is_valid_package_id(Package::ERROR_PACKAGE_ID));
  Package error_package(Package::ERROR_PACKAGE_ID,
                        Package::NO_NAME,
                        std::string(""),  // Doesn't matter. Should never be used.
                        std::string(""),  // Doesn't matter. Should never be used.
                        std::string(""),  // Doesn't matter. Should never be used.
                        Package::STATE_ERROR,
                        {},
                        false);  // Not a path package.
  // Note that the virtual package must not be added to the path-to-package map.
  packages[Package::ERROR_PACKAGE_ID] = error_package;

  auto sdk_lib_path = build_canonical_sdk_dir(fs);
  bool sdk_is_dir = fs->is_directory(sdk_lib_path.c_str());

  // Prefixes that can be used directly (such as `import math`).
  Set<std::string> sdk_prefixes;

  if (sdk_is_dir) {
    fs->list_toit_directory_entries(sdk_lib_path.c_str(), [&](const char* entry, bool is_directory) {
      sdk_prefixes.insert(std::string(entry));
      return true;
    });
  }

  ASSERT(!is_valid_package_id(Package::SDK_PACKAGE_ID));
  Package sdk_package(Package::SDK_PACKAGE_ID,
                      Package::NO_NAME,
                      sdk_lib_path,
                      sdk_lib_path,
                      std::string(fs->library_root()),
                      sdk_is_dir ? Package::STATE_OK : Package::STATE_NOT_FOUND,
                      no_prefixes,
                      false);  // Not a path package.
  packages[Package::SDK_PACKAGE_ID] = sdk_package;

  // Path to the lock directory.
  char package_lock_dir[PATH_MAX];
  package_lock_dir[0] = '\0';

  std::string entry_pkg_path;
  if (lock_content.source == null) {
    // If there is no package-lock file, applications are allowed to dot out as much
    // as they want.
    // Since we store paths without the trailing "/", we store "" for the filesystem root.
    entry_pkg_path = std::string("");
  } else {
    // Otherwise, the "entry" package starts at the lock-file folder.
    Filesystem::dirname(lock_content.source->absolute_path(), package_lock_dir, PATH_MAX);
    entry_pkg_path = std::string(package_lock_dir);
  }

  Map<std::string, std::string> entry_prefixes;
  auto entry_prefix_probe = lock_content.prefixes.find(Package::ENTRY_PACKAGE_ID);
  if (entry_prefix_probe != lock_content.prefixes.end()) {
    entry_prefixes = entry_prefix_probe->second;
  }

  ASSERT(!is_valid_package_id(Package::ENTRY_PACKAGE_ID));
  std::string root(fs->root(entry_path));
  std::string absolute_error_path = root;
  std::string relative_error_path = root;
  if (!entry_is_absolute) {
    // On Windows this is a drive-relative path.
    if (fs->is_path_separator(entry_path[0])) {
      relative_error_path = std::string(fs->relative_anchor("\\"));
      absolute_error_path = relative_error_path;
    } else {
      relative_error_path = std::string(".");
      absolute_error_path = std::string(fs->cwd());
    }
  }
  Package entry_package(Package::ENTRY_PACKAGE_ID,
                        std::string(""),
                        entry_pkg_path,
                        absolute_error_path,
                        relative_error_path,
                        Package::STATE_OK,
                        entry_prefixes,
                        true);  // Referenced through a path, thus considered a path package.
  packages[Package::ENTRY_PACKAGE_ID] = entry_package;

  List<const char*> package_dirs;
  if (lock_content.source != null) {
    // We only ask for the package-cache paths from the filesystem when we need them.
    ListBuilder<const char*> builder;

    // Add the local (to the application) package directory.
    PathBuilder path_builder(fs);
    path_builder.join(lock_file_path);
    path_builder.join("..");
    path_builder.join(LOCAL_PACKAGE_DIR);
    path_builder.canonicalize();

    builder.add(path_builder.strdup());

    // Add the other package caches as fallbacks.
    builder.add(fs->package_cache_paths());

    package_dirs = builder.build();
  }

  Map<std::string, Map<std::string, std::string>> mappings;
  fill_package_mappings(&mappings, package_dirs, fs);

  Map<std::string, std::string> path_to_package;
  for (auto package_id : lock_content.packages.keys()) {
    auto entry = lock_content.packages.at(package_id);

    auto locate_package = [&](std::string path, const std::string& error_path, bool is_path_package) -> Package {
      if (fs->exists(path.c_str()) && fs->is_directory(path.c_str())) {
        PathBuilder src_builder(fs);
        src_builder.join(path, PACKAGE_SOURCE_DIR);
        auto src_path = src_builder.buffer();

        if (fs->exists(src_path.c_str()) && fs->is_directory(src_path.c_str())) {
          path = src_path;
          auto path_probe = path_to_package.find(path);
          if (path_probe != path_to_package.end()) {
            diagnostics->report_error(entry.range,
                                      "Path of package '%s' is same as for '%s': '%s'",
                                      package_id.c_str(),
                                      path_probe->second.c_str(),
                                      error_path.c_str());
          } else {
            path_to_package[path] = package_id;
          }
          Map<std::string, std::string> package_prefixes;
          auto prefix_probe = lock_content.prefixes.find(package_id);
          if (prefix_probe != lock_content.prefixes.end()) {
            package_prefixes = prefix_probe->second;
          }
          return Package(package_id,
                         entry.name,
                         path,
                         path,
                         path,
                         Package::STATE_OK,
                         package_prefixes,
                         is_path_package);
        } else {
          diagnostics->report_error(entry.range,
                          "Package '%s' at '%s' is missing a '%s' folder",
                          package_id.c_str(),
                          path.c_str(),
                          PACKAGE_SOURCE_DIR);
          return Package(package_id,
                         entry.name,
                         std::string(""),
                         std::string(""),
                         std::string(""),
                         Package::STATE_NOT_FOUND,
                         {},  // The prefixes aren't relevant.
                         is_path_package);
        }
      }
      return Package::invalid();
    };

    auto package = Package::invalid();
    bool is_path_package = !entry.path.empty();
    if (is_path_package) {
      PathBuilder builder(fs);

      std::string error_path;
      // The entry_path is always with slashes.
      auto entry_path = entry.path.c_str();
      char* localized = FilesystemLocal::to_local_path(entry_path);
      if (!fs->is_absolute(localized)) {
        // TODO(florian): this is not correct for Windows paths that are drive-relative: '\foo'.
        builder.add(package_lock_dir);
      }
      builder.join_slash_path(std::string(entry_path));
      builder.canonicalize();
      error_path = std::string(localized);
      free(localized);
      auto path = builder.buffer();

      package = locate_package(path, error_path, is_path_package);
      if (!package.is_valid()) {
        diagnostics->report_error(entry.range,
                                  "Package '%s' not found at '%s'",
                                  entry.path.c_str(),
                                  path.c_str());
      }
    } else if (entry.url != "" && entry.version != "") {
      // Not a path package.
      auto error_path = entry.url + "-" + entry.version;
      // Try the mappings first.
      {
        PathBuilder builder(fs);
        auto path_probe = mappings.find(entry.url);
        if (path_probe != mappings.end()) {
          auto version_probe = path_probe->second.find(entry.version);
          if (version_probe != path_probe->second.end()) {
            builder.join(version_probe->second);
            builder.canonicalize();
            auto path = builder.buffer();
            package = locate_package(path, error_path, is_path_package);
          }
        }
      }
      // Try in the package-directories.
      for (int i = 0; !package.is_valid() && i < package_dirs.length(); i++) {
        PathBuilder builder(fs);
        if (!fs->is_absolute(package_dirs[i])) {
          // TODO(florian): this is not correct for Windows paths that are drive-relative: '\foo'.
          builder.join(fs->cwd());
        }
        builder.join(package_dirs[i]);
        builder.join(entry.url);
        builder.join(entry.version);
        builder.canonicalize();
        auto path = builder.buffer();
        package = locate_package(path, error_path, is_path_package);
      }
      if (!package.is_valid()) {
        diagnostics->report_error(entry.range,
                                  "Package '%s-%s' not found",
                                  entry.url.c_str(),
                                  entry.version.c_str());
      }
    }
    if (!package.is_valid()) {
      package = Package(package_id,
                        entry.name,
                        std::string(""),
                        std::string(""),
                        std::string(""),
                        Package::STATE_NOT_FOUND,
                        {},  // The prefixes aren't relevant.
                        is_path_package);
    }
    packages[package_id] = package;
  }
  return PackageLock(lock_content.source,
                     lock_content.sdk_constraint,
                     packages,
                     sdk_prefixes,
                     lock_content.has_errors);
}


} // namespace toit::compiler
} // namespace toit
