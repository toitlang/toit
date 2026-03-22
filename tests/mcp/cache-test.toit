// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
  test-project-scoped-isolation

/**
Creates a DocCache backed by a CLI Cache in a temporary directory.
Calls the given $block with the temporary directory and the cache.
*/
with-doc-cache [block] -> none:
  tmp-dir := directory.mkdtemp "/tmp/cache-test-"
  try:
    backing := cli-cache.Cache --app-name="test" --path=tmp-dir
    cache := DocCache backing
    block.call tmp-dir cache
  finally:
    directory.rmdir --recursive --force tmp-dir

test-get-miss:
  with-doc-cache: | tmp-dir/string cache/DocCache |
    result := cache.get --key="nonexistent"
    expect-null result

test-put-and-get:
  with-doc-cache: | tmp-dir/string cache/DocCache |
    data := {"name": "test", "value": 42}
    cache.put --key="my-key": data
    result := cache.get --key="my-key"
    expect-not-null result
    expect-equals "test" result["name"]
    expect-equals 42 result["value"]

test-sdk-key:
  key := DocCache.sdk-key --version="v2.0.0"
  expect-equals "sdk-v2.0.0" key

test-package-key:
  key := DocCache.package-key --id="github.com/toitlang/pkg-http" --version="2.11.0"
  expect-equals "github.com%2Ftoitlang%2Fpkg-http@2.11.0" key

test-put-is-noop-if-exists:
  with-doc-cache: | tmp-dir/string cache/DocCache |
    cache.put --key="same-key": {"version": 1}
    // Second put is a no-op since the key already exists.
    cache.put --key="same-key": {"version": 2}
    result := cache.get --key="same-key"
    expect-not-null result
    // The first value is kept.
    expect-equals 1 result["version"]

test-multiple-keys:
  with-doc-cache: | tmp-dir/string cache/DocCache |
    cache.put --key="alpha": {"id": "a"}
    cache.put --key="beta": {"id": "b"}
    result-a := cache.get --key="alpha"
    result-b := cache.get --key="beta"
    expect-not-null result-a
    expect-not-null result-b
    expect-equals "a" result-a["id"]
    expect-equals "b" result-b["id"]

test-roundtrip-complex-json:
  with-doc-cache: | tmp-dir/string cache/DocCache |
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
    cache.put --key="sdk-v2.0.0": complex-data
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

test-project-scoped-isolation:
  with-doc-cache: | tmp-dir/string cache/DocCache |
    key := "pkg@1.0"
    // Store under project A.
    cache.put --key=key --project-root="/project/a": {"from": "a"}
    // Store under project B.
    cache.put --key=key --project-root="/project/b": {"from": "b"}
    // Store without project scope.
    cache.put --key=key: {"from": "global"}

    // Each scope should return its own value.
    result-a := cache.get --key=key --project-root="/project/a"
    expect-not-null result-a
    expect-equals "a" result-a["from"]

    result-b := cache.get --key=key --project-root="/project/b"
    expect-not-null result-b
    expect-equals "b" result-b["from"]

    result-global := cache.get --key=key
    expect-not-null result-global
    expect-equals "global" result-global["from"]
