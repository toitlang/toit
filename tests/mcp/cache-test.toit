// Copyright (C) 2026 Toitware ApS.
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

import expect show *
import cli.cache as cli-cache
import host.directory
import host.file

import ...tools.mcp.cache show DocCache

main:
  test-get-miss
  test-put-and-get
  test-sdk-key
  test-package-key
  test-put-is-noop-if-exists
  test-multiple-keys
  test-roundtrip-complex-json

/// Creates a DocCache backed by a CLI Cache in the given $tmp-dir.
create-doc-cache tmp-dir/string -> DocCache:
  backing := cli-cache.Cache --app-name="test" --path=tmp-dir
  return DocCache backing

test-get-miss:
  tmp-dir := directory.mkdtemp "/tmp/cache-test-"
  try:
    cache := create-doc-cache tmp-dir
    result := cache.get --key="nonexistent"
    expect-null result
  finally:
    directory.rmdir --recursive tmp-dir

test-put-and-get:
  tmp-dir := directory.mkdtemp "/tmp/cache-test-"
  try:
    cache := create-doc-cache tmp-dir
    data := {"name": "test", "value": 42}
    cache.put --key="my-key" --data=data
    result := cache.get --key="my-key"
    expect-not-null result
    expect-equals "test" result["name"]
    expect-equals 42 result["value"]
  finally:
    directory.rmdir --recursive tmp-dir

test-sdk-key:
  key := DocCache.sdk-key --version="v2.0.0"
  expect-equals "sdk-v2.0.0" key

test-package-key:
  key := DocCache.package-key --id="github.com/toitlang/pkg-http" --version="2.11.0"
  expect-equals "github.com%2Ftoitlang%2Fpkg-http@2.11.0" key

test-put-is-noop-if-exists:
  tmp-dir := directory.mkdtemp "/tmp/cache-test-"
  try:
    cache := create-doc-cache tmp-dir
    cache.put --key="same-key" --data={"version": 1}
    // Second put is a no-op since the key already exists.
    cache.put --key="same-key" --data={"version": 2}
    result := cache.get --key="same-key"
    expect-not-null result
    // The first value is kept.
    expect-equals 1 result["version"]
  finally:
    directory.rmdir --recursive tmp-dir

test-multiple-keys:
  tmp-dir := directory.mkdtemp "/tmp/cache-test-"
  try:
    cache := create-doc-cache tmp-dir
    cache.put --key="alpha" --data={"id": "a"}
    cache.put --key="beta" --data={"id": "b"}
    result-a := cache.get --key="alpha"
    result-b := cache.get --key="beta"
    expect-not-null result-a
    expect-not-null result-b
    expect-equals "a" result-a["id"]
    expect-equals "b" result-b["id"]
  finally:
    directory.rmdir --recursive tmp-dir

test-roundtrip-complex-json:
  tmp-dir := directory.mkdtemp "/tmp/cache-test-"
  try:
    cache := create-doc-cache tmp-dir
    complex-data := {
      "sdk-version": "v2.0.0",
      "libraries": [
        {
          "name": "core",
          "modules": [
            {
              "name": "collections",
              "classes": [
                {
                  "name": "List",
                  "methods": ["add", "remove", "size"],
                },
              ],
            },
          ],
        },
      ],
      "metadata": {
        "generated-at": "2024-01-01",
        "generator": "toitdoc",
      },
    }
    cache.put --key="sdk-v2.0.0" --data=complex-data
    result := cache.get --key="sdk-v2.0.0"
    expect-not-null result
    expect-equals "v2.0.0" result["sdk-version"]
    libraries := result["libraries"] as List
    expect-equals 1 libraries.size
    first-lib := libraries[0] as Map
    expect-equals "core" first-lib["name"]
    modules := first-lib["modules"] as List
    first-module := modules[0] as Map
    classes := first-module["classes"] as List
    first-class := classes[0] as Map
    expect-equals "List" first-class["name"]
    methods := first-class["methods"] as List
    expect-equals 3 methods.size
    expect-equals "add" methods[0]
    metadata := result["metadata"] as Map
    expect-equals "toitdoc" metadata["generator"]
  finally:
    directory.rmdir --recursive tmp-dir
