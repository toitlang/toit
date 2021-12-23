// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.file
import host.directory
import expect show *
import writer show Writer
import encoding.json as json
import host.pipe

import .lock_parser

SHARED_CACHE_DIR ::= ".cache/toit/tpkg"
LOCAL_PACKAGE_DIR ::= ".packages"

write_to_file path content:
  stream := file.Stream.for_write path
  (Writer stream).write content
  stream.close

copy_all source_dir target_dir:
  directory.mkdir --recursive target_dir
  stream := directory.DirectoryStream source_dir
  while next := stream.next:
    copy_all next source_dir target_dir

copy_all entry source_dir target_dir:
  source_path := "$source_dir/$entry"
  last_segment := (entry.split "/").last
  target_path := "$target_dir/$last_segment"
  if file.is_directory source_path:
    copy_all source_path target_path
  else:
    content := file.read_content source_path
    write_to_file target_path content


read_lock_file path:
  content_string := (file.read_content path).to_string
  result := parse_lock_file content_string
  // For simplicity add empty prefixes and packages if they don't exist.
  result.get "prefixes" --init=:{:}
  result.get "packages" --init=:{:}
  return result

update_package_entries lock_content/Map [update_block] -> Map:
  result := {:}
  packages := lock_content["packages"]
  result["packages"] = packages.map: | id/string entry |
    path := entry["path"]
    expect path != ""
    new_entry := update_block.call path
    entry.get "prefixes" --if_present=: new_entry["prefixes"] = it
    new_entry
  lock_content.get "prefixes" --if_present=: result["prefixes"] = it
  return result

make_absolute lock_content/Map test_dir/string -> Map:
  return update_package_entries lock_content:
    {
      // Make the path absolute.
      "path": "$test_dir/$it"
    }

make_package lock_content/Map test_dir/string cache_dir/string -> Map:
  already_copied := {}
  return update_package_entries lock_content: | path / string |
    parts := path.split "/"
    root_dir := parts.first
    // We will use a different name for the pkg-dir, so we don't accidentally use the
    //   relative directory.
    replaced_root_dir := "$(root_dir)_IN_PKG_DIR"
    parts[0] = replaced_root_dir
    replaced_path := parts.join "/"
    version := "1.0.0"
    if not already_copied.contains path:
      copy_all "$test_dir/$path" "$cache_dir/$replaced_path/$version"
      already_copied.add path
    {
      "url": replaced_path,
      "version": version,
    }

/** Recursively finds all files in the given $dir and calls $block with each file */
find dir/string [block]:
  stream := directory.DirectoryStream dir
  while entry := stream.next:
    path := "$dir/$entry"
    if file.is_directory path:
      find path block
    else:
      block.call path
  stream.close

main args:
  toitc := args[0]
  dir := args[1]
  last_segment := (dir.split "/").last

  tmp_dir := directory.mkdtemp "/tmp/test-abs-"
  try:
    copy_all dir "." tmp_dir
    test_dir := "$tmp_dir/$last_segment"
    lock_path := "$test_dir/package.lock"
    main_path := "$test_dir/test.toit"
    lock_content /Map := read_lock_file lock_path
    absolute_lock_content := make_absolute lock_content test_dir
    // For simplicity write the content as JSON. Since Yaml is pretty much a
    // super-set of JSON this is valid.
    write_to_file lock_path (json.stringify absolute_lock_content)
    // The program should still complete successfully with absolute paths.
    pipe.backticks toitc main_path

    fake_home_dir := "$test_dir/FAKE_HOME"
    shared_cache_dir := "$fake_home_dir/$SHARED_CACHE_DIR"
    directory.mkdir --recursive shared_cache_dir

    // Do the same, but now with a package directory.
    package_lock_content := make_package lock_content test_dir shared_cache_dir
    // For simplicity write the content as JSON. Since Yaml is pretty much a
    // super-set of JSON this is valid.
    write_to_file lock_path (json.stringify package_lock_content)
    // We don't want to access the real home-directory cache, so provide a fake one with the HOME env variable.
    pipe.backticks "sh" "-c" "HOME=\"$fake_home_dir\" \"$toitc\" \"$main_path\""
    // Check that it doesn't work with a non-existing directory.
    if not lock_content["prefixes"].is_empty:
      exit_code := pipe.system "HOME=\"NON_EXISTING_PATH\" \"$toitc\" \"$main_path\" > /dev/null"
      expect_equals 1 exit_code
    // The `TOIT_PACKAGE_CACHE_PATHS` takes precedence over the home package cache.
    pipe.backticks "sh" "-c" "HOME=\"NON_EXISTING_PATH\" TOIT_PACKAGE_CACHE_PATHS=\"$fake_home_dir/$SHARED_CACHE_DIR\" \"$toitc\" \"$main_path\""
    // Check that it also works if there are multiple entries (separated by ":")
    pipe.backticks "sh" "-c" "HOME=\"NON_EXISTING_PATH\" TOIT_PACKAGE_CACHE_PATHS=\"NON_EXISTING_PATH:$fake_home_dir/$SHARED_CACHE_DIR\" \"$toitc\" \"$main_path\""
    pipe.backticks "sh" "-c" "HOME=\"NON_EXISTING_PATH\" TOIT_PACKAGE_CACHE_PATHS=\"$fake_home_dir/$SHARED_CACHE_DIR:NON_EXISTING_PATH\" \"$toitc\" \"$main_path\""

    // Modify the shared cache directory so that it now yields errors.
    find shared_cache_dir: | path/string |
      if path.ends_with ".toit":
        write_to_file path "WOULD BE AN ERROR IF FOUND"

    // Now save the packages directly in the package dir.
    local_package_dir := "$test_dir/$LOCAL_PACKAGE_DIR"
    directory.mkdir local_package_dir
    package_lock_content_local := make_package lock_content test_dir local_package_dir

    expect_equals
        json.stringify package_lock_content
        json.stringify package_lock_content_local

    // This local package dir is now found and preferred.
    pipe.backticks toitc main_path
    pipe.backticks "sh" "-c" "HOME=\"$fake_home_dir\" \"$toitc\" \"$main_path\""

  finally:
    directory.rmdir --recursive tmp_dir
