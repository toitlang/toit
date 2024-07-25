// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.os
import host.directory
import host.file
import encoding.yaml

TOIT-REGISTRY-MAP := {
    "url": "github.com/toitware/registry",
    "type": "git",
    "ref-hash": "c566e03d79f65b71104a1cb1b680284f6a5ac179",
}

with-test-registry [block]:
  tmp-dir := directory.mkdtemp "/tmp/test-"
  try:
    os.env["TOIT_PKG_CACHE_DIR"] = ".test-cache"
    directory.mkdir --recursive ".test-cache"
    file.write-content --path=".test-cache/registries.yaml"
        yaml.encode {"toit": TOIT-REGISTRY-MAP}

    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir
