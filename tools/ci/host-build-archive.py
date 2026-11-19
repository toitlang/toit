#!/usr/bin/env python3
# Zero-Clause BSD License

# Copyright (C) 2026 Toit contributors.

# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted.

# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.

"""Transfer an incremental host build between CI runners.

Ninja's dependency database records nanosecond object timestamps. Use a PAX tar
archive to retain those timestamps, permissions, and symlinks. Restore checkout
timestamps too: a fresh checkout would otherwise make every source newer than
the objects. CMake build trees also require the same absolute workspace path.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


METADATA = "host-build-metadata.json"
BUILD_DIRS = ("build", "build-debug")
# Host CMake still reads mbedTLS's build scripts and headers in test shards.
# Transfer the sources without Git metadata instead of cloning ESP-IDF again.
SOURCE_DIRS = ("third_party/esp-idf/components/mbedtls",)


def git(*args):
    return subprocess.check_output(["git", *args])


def pack(archive):
    workspace = Path.cwd().resolve()
    sources = git("ls-files", "--recurse-submodules", "-z").split(b"\0")
    mtimes = {}
    for name in sources:
        if not name:
            continue
        path = Path(os.fsdecode(name))
        if path.is_file() and not path.is_symlink():
            mtimes[path.as_posix()] = path.stat().st_mtime_ns

    paths = [name for name in (*BUILD_DIRS, *SOURCE_DIRS) if Path(name).is_dir()]
    # Bootstrap packages are inputs to the embedded SDK programs. Keep their
    # depfile paths and timestamps, as well as ordinary test package downloads.
    for directory, dirs, _ in os.walk("."):
        dirs[:] = sorted(name for name in dirs if name not in (".git", ".ccache"))
        if directory == ".":
            dirs[:] = [name for name in dirs if name not in BUILD_DIRS]
        for name in list(dirs):
            if name in (".packages", ".packages-bootstrap"):
                paths.append((Path(directory) / name).as_posix())
                dirs.remove(name)
                # Package installation can rewrite the lock file.
                for manifest in ("package.yaml", "package.lock"):
                    path = Path(directory) / manifest
                    if path.is_file() and path.as_posix() not in paths:
                        paths.append(path.as_posix())

    metadata = {
        "workspace": str(workspace),
        "commit": git("rev-parse", "HEAD").decode().strip(),
        "source_mtimes": mtimes,
    }
    # Keep metadata first in the archive. All tar options must precede the
    # filenames for compatibility with both GNU tar and BSD tar.
    with Path(METADATA).open("x", encoding="utf-8") as output:
        json.dump(metadata, output)
    try:
        with tempfile.TemporaryDirectory() as temp:
            file_list = Path(temp) / "files"
            file_list.write_bytes(b"\0".join(
                os.fsencode(path) for path in [METADATA, *paths]) + b"\0")
            # Use stdout/stdin for the archive so GNU tar doesn't interpret a
            # Windows drive letter as a remote host.
            with archive.open("wb") as output:
                subprocess.run([
                    "tar", "--format=pax", "-czf", "-",
                    "--exclude=.git", "--null", "-T", str(file_list),
                ], stdout=output, check=True)
    finally:
        Path(METADATA).unlink()


def unpack(archive):
    # Inspect metadata before extracting: build trees cannot be relocated, and
    # a failed-job rerun must consume a build of the same commit.
    # Metadata is first so validation doesn't decompress the entire build
    # before tar decompresses it again to extract the files.
    with tarfile.open(archive, "r|gz") as source:
        member = source.next()
        if member is None or member.name != METADATA:
            raise RuntimeError("Missing host build metadata")
        metadata = json.load(source.extractfile(member))
    if metadata["workspace"] != str(Path.cwd().resolve()):
        raise RuntimeError("The host build requires the same absolute workspace path")
    if metadata["commit"] != git("rev-parse", "HEAD").decode().strip():
        raise RuntimeError("The host build is from a different commit")
    with archive.open("rb") as source:
        subprocess.run(["tar", "-xzf", "-"], stdin=source, check=True)
    Path(METADATA).unlink()
    for name, mtime in metadata["source_mtimes"].items():
        path = Path(name)
        # Uninitialized optional submodules aren't needed by the host build.
        if path.is_file() and not path.is_symlink():
            os.utime(path, ns=(mtime, mtime))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("pack", "unpack"))
    parser.add_argument("archive", type=lambda value: Path(value).resolve())
    args = parser.parse_args()
    {"pack": pack, "unpack": unpack}[args.command](args.archive)


if __name__ == "__main__":
    main()
