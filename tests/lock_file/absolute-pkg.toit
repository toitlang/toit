// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json as json
import expect show *
import host.file
import host.directory
import host.pipe
import io

import .lock-parser

SHARED-CACHE-DIR ::= ".cache/toit/tpkg"
LOCAL-PACKAGE-DIR ::= ".packages"

write-to-file path content:
  stream := file.Stream.for-write path
  (io.Writer.adapt stream).write content
  stream.close

copy-all source-dir target-dir:
  directory.mkdir --recursive target-dir
  stream := directory.DirectoryStream source-dir
  while next := stream.next:
    copy-all next source-dir target-dir

copy-all entry source-dir target-dir:
  source-path := "$source-dir/$entry"
  last-segment := (entry.split "/").last
  target-path := "$target-dir/$last-segment"
  if file.is-directory source-path:
    copy-all source-path target-path
  else:
    content := file.read-contents source-path
    write-to-file target-path content


read-lock-file path:
  content-string := (file.read-contents path).to-string
  result := parse-lock-file content-string
  // For simplicity add empty prefixes and packages if they don't exist.
  result.get "prefixes" --init=:{:}
  result.get "packages" --init=:{:}
  return result

update-package-entries lock-content/Map [update-block] -> Map:
  result := {:}
  packages := lock-content["packages"]
  result["packages"] = packages.map: | id/string entry |
    path := entry["path"]
    expect path != ""
    new-entry := update-block.call path
    entry.get "prefixes" --if-present=: new-entry["prefixes"] = it
    new-entry
  lock-content.get "prefixes" --if-present=: result["prefixes"] = it
  return result

make-absolute lock-content/Map test-dir/string -> Map:
  return update-package-entries lock-content:
    {
      // Make the path absolute.
      "path": "$test-dir/$it"
    }

make-package lock-content/Map test-dir/string cache-dir/string -> Map:
  already-copied := {}
  return update-package-entries lock-content: | path / string |
    parts := path.split "/"
    root-dir := parts.first
    // We will use a different name for the pkg-dir, so we don't accidentally use the
    //   relative directory.
    replaced-root-dir := "$(root-dir)_IN_PKG_DIR"
    parts[0] = replaced-root-dir
    replaced-path := parts.join "/"
    version := "1.0.0"
    if not already-copied.contains path:
      copy-all "$test-dir/$path" "$cache-dir/$replaced-path/$version"
      already-copied.add path
    {
      "url": replaced-path,
      "version": version,
    }

/** Recursively finds all files in the given $dir and calls $block with each file */
find dir/string [block]:
  stream := directory.DirectoryStream dir
  while entry := stream.next:
    path := "$dir/$entry"
    if file.is-directory path:
      find path block
    else:
      block.call path
  stream.close

main args:
  toit-run := args[0]
  dir := args[1]
  last-segment := (dir.split "/").last

  tmp-dir := directory.mkdtemp "/tmp/test-abs-"
  try:
    copy-all dir "." tmp-dir
    test-dir := "$tmp-dir/$last-segment"
    lock-path := "$test-dir/package.lock"
    main-path := "$test-dir/test.toit"
    lock-content /Map := read-lock-file lock-path
    absolute-lock-content := make-absolute lock-content test-dir
    // For simplicity write the content as JSON. Since Yaml is pretty much a
    // super-set of JSON this is valid.
    write-to-file lock-path (json.stringify absolute-lock-content)
    // The program should still complete successfully with absolute paths.
    pipe.backticks toit-run main-path

    fake-home-dir := "$test-dir/FAKE_HOME"
    shared-cache-dir := "$fake-home-dir/$SHARED-CACHE-DIR"
    directory.mkdir --recursive shared-cache-dir

    // Do the same, but now with a package directory.
    package-lock-content := make-package lock-content test-dir shared-cache-dir
    // For simplicity write the content as JSON. Since Yaml is pretty much a
    // super-set of JSON this is valid.
    write-to-file lock-path (json.stringify package-lock-content)
    // We don't want to access the real home-directory cache, so provide a fake one with the HOME env variable.
    pipe.backticks "sh" "-c" "HOME=\"$fake-home-dir\" \"$toit-run\" \"$main-path\""
    // Check that it doesn't work with a non-existing directory.
    if not lock-content["prefixes"].is-empty:
      exit-code := pipe.system "HOME=\"NON_EXISTING_PATH\" \"$toit-run\" \"$main-path\" > /dev/null"
      expect-equals 1 exit-code
    // The `TOIT_PACKAGE_CACHE_PATHS` takes precedence over the home package cache.
    pipe.backticks "sh" "-c" "HOME=\"NON_EXISTING_PATH\" TOIT_PACKAGE_CACHE_PATHS=\"$fake-home-dir/$SHARED-CACHE-DIR\" \"$toit-run\" \"$main-path\""
    // Check that it also works if there are multiple entries (separated by ":")
    pipe.backticks "sh" "-c" "HOME=\"NON_EXISTING_PATH\" TOIT_PACKAGE_CACHE_PATHS=\"NON_EXISTING_PATH:$fake-home-dir/$SHARED-CACHE-DIR\" \"$toit-run\" \"$main-path\""
    pipe.backticks "sh" "-c" "HOME=\"NON_EXISTING_PATH\" TOIT_PACKAGE_CACHE_PATHS=\"$fake-home-dir/$SHARED-CACHE-DIR:NON_EXISTING_PATH\" \"$toit-run\" \"$main-path\""

    // Modify the shared cache directory so that it now yields errors.
    find shared-cache-dir: | path/string |
      if path.ends-with ".toit":
        write-to-file path "WOULD BE AN ERROR IF FOUND"

    // Now save the packages directly in the package dir.
    local-package-dir := "$test-dir/$LOCAL-PACKAGE-DIR"
    directory.mkdir local-package-dir
    package-lock-content-local := make-package lock-content test-dir local-package-dir

    expect-equals
        json.stringify package-lock-content
        json.stringify package-lock-content-local

    // This local package dir is now found and preferred.
    pipe.backticks toit-run main-path
    pipe.backticks "sh" "-c" "HOME=\"$fake-home-dir\" \"$toit-run\" \"$main-path\""

  finally:
    directory.rmdir --recursive tmp-dir
