#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
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

"""Packs the native support of a firmware build.

The native support has what it takes to link firmware with generated native
code, without the build directory: the libraries, the linker scripts, and
a recipe with the commands. The firmware tool uses it to link the code
that it generates when it extracts native firmware from an envelope.

Paths in the recipe are relative to the native support and start with
'{support}/'. The generated object is '{native}' and the linked ELF file is
'{output}'.
"""

import argparse
import io
import json
import os
import shlex
import subprocess
import tarfile
import tempfile

SUPPORT_VERSION = 1

def ninja_command(ninja, build_dir, target):
  output = subprocess.run([ninja, "-C", build_dir, "-t", "commands", target],
                          check=True, capture_output=True, text=True).stdout
  return output.strip().splitlines()[-1]

class NativeSupport:
  def __init__(self, build_dir, idf_path, strip):
    self.build_dir = os.path.realpath(build_dir)
    self.idf_path = os.path.realpath(idf_path)
    self.strip = strip
    self.files = {}  # Path in the native support -> path on disk.

  def support_path(self, path):
    """Returns the path in the native support for the given path on disk."""
    path = os.path.realpath(os.path.join(self.build_dir, path))
    for prefix, root in [("build", self.build_dir), ("idf", self.idf_path)]:
      if path.startswith(root + os.sep):
        return prefix + "/" + os.path.relpath(path, root).replace(os.sep, "/")
    raise Exception("Path outside of the build and IDF directories: " + path)

  def add_file(self, path):
    support_path = self.support_path(path)
    self.files[support_path] = os.path.realpath(os.path.join(self.build_dir, path))
    return "{support}/" + support_path

  def add_directory(self, path):
    """Adds the linker scripts and libraries in the given directory."""
    full = os.path.realpath(os.path.join(self.build_dir, path))
    for name in sorted(os.listdir(full)):
      if name.endswith(".ld") or name.endswith(".a"):
        self.add_file(os.path.join(full, name))
    return "{support}/" + self.support_path(path)

  def write(self, output, recipe):
    with tempfile.TemporaryDirectory() as tmp:
      # The tar reader of the firmware tool handles GNU long names, but not PAX.
      with tarfile.open(output, "w:gz", format=tarfile.GNU_FORMAT) as tar:
        # The recipe comes first, so it can be read without the rest.
        data = json.dumps(recipe, indent=2).encode()
        info = tarfile.TarInfo("recipe.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
        for support_path, path in sorted(self.files.items()):
          if path.endswith(".a"):
            # The debug information is most of the size and isn't needed to link.
            stripped = os.path.join(tmp, "stripped.a")
            subprocess.run([self.strip, "--strip-debug", "-o", stripped, path], check=True)
            path = stripped
          tar.add(path, arcname=support_path)

def link_recipe(support, command, elf_name):
  args = shlex.split(command)
  # Ninja wraps the link command in ': && ... && :'.
  while args and args[0] in [":", "&&"]: args.pop(0)
  while args and args[-1] in [":", "&&"]: args.pop()
  linker = os.path.basename(args.pop(0))
  result = []
  added_native = False
  i = 0
  while i < len(args):
    arg = args[i]
    i += 1
    if arg.startswith("-Wl,--Map=") or arg == "-Wl,--cref":
      continue
    if arg == "-o":
      result += ["-o", "{output}"]
      i += 1
      continue
    if arg.startswith("-L"):
      result.append("-L" + support.add_directory(arg[2:]))
      continue
    if arg.endswith(".a") or arg.endswith(".obj") or arg.endswith(".o"):
      if not added_native:
        # The generated code registers itself, so nothing refers to it.
        result += ["-Wl,--whole-archive", "{native}", "-Wl,--no-whole-archive"]
        added_native = True
      result.append(support.add_file(arg))
      continue
    result.append(arg)
  return linker, result

def elf2image_recipe(command):
  args = shlex.split(command.split("&&")[1] if command.startswith("cd ") else command)
  index = args.index("elf2image")
  chip_index = args.index("--chip")
  options = args[index + 1:]
  result = ["--chip", args[chip_index + 1], "elf2image"]
  i = 0
  while i < len(options) - 1:  # The last one is the ELF file.
    if options[i] == "-o":
      i += 2
      continue
    result.append(options[i])
    i += 1
  return result + ["-o", "{output}", "{elf}"]

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--build-dir", required=True)
  parser.add_argument("--idf-path", required=True)
  parser.add_argument("--ninja", required=True)
  parser.add_argument("--strip", required=True)
  parser.add_argument("--elf", required=True, help="The name of the ELF target.")
  parser.add_argument("--binary-target", required=True, help="The target that runs elf2image.")
  parser.add_argument("--chip", required=True)
  parser.add_argument("--cxx-flags", required=True, help="The flags to compile generated code with.")
  parser.add_argument("--toit", required=True, help="The toit executable, for the SDK version.")
  parser.add_argument("-o", "--output", required=True)
  args = parser.parse_args()

  support = NativeSupport(args.build_dir, args.idf_path, args.strip)
  linker, link = link_recipe(support, ninja_command(args.ninja, args.build_dir, args.elf), args.elf)
  elf2image = elf2image_recipe(ninja_command(args.ninja, args.build_dir, args.binary_target))
  recipe = {
    "version": SUPPORT_VERSION,
    "sdk-version": subprocess.run([args.toit, "version"], check=True, capture_output=True, text=True).stdout.strip(),
    "chip": args.chip,
    "compile": shlex.split(args.cxx_flags),
    "linker": linker,
    "link": link,
    "elf2image": elf2image,
  }
  support.write(args.output, recipe)

if __name__ == "__main__":
  main()
