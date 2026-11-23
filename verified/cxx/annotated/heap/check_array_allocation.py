# Copyright (C) 2026 Toit contributors.
"""Check the native array constructor using the verified initializer's postcondition."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    mode, bits, src, scratch, harness, esbmc, *flags = sys.argv[1:]
    if mode not in ("proof", "young-filler", "old-filler", "unmarked-old"):
        raise ValueError(mode)
    source = (Path(src) / "heap.cc").read_text()
    # Retain the actual arguments and receiver. Match the entire call so that
    # a change to the composition requires a new check.
    call = "Array::cast(result)->_initialize_no_write_barrier(length, filler);"
    if source.count(call) != 1:
        raise ValueError("expected one array initialization call in heap.cc")
    filler = {"young-filler": "old_requests ? filler : nullptr",
              "old-filler": "old_requests ? nullptr : filler"}.get(mode, "filler")
    summary = f"checked_array_init(Array::cast(result), length, {filler});"
    space_dir = Path(src) / "third_party" / "dartino"
    spaces = (space_dir / "two_space_heap.cc").read_text()
    if mode == "unmarked-old":
        mark = "GcMetadata::insert_into_remembered_set(address);"
        if spaces.count(mark) != 1:
            raise ValueError("expected one direct old-space allocation card mark")
        spaces = spaces.replace(mark, "")
    model = Path(__file__).resolve().parents[1] / "model"
    constants = []
    for filename, name in (("objects.render", "MAX_OBJECT_WORDS"),
                           ("constants.h", "LAYOUT_ARRAY_LENGTH_WORD"),
                           ("constants.h", "LAYOUT_ARRAY_ELEMENTS_WORD")):
        definition, = re.findall(rf"^#define {name} (?:0x[0-9a-fA-F]+|[0-9]+)$",
                                 (model / filename).read_text(), re.MULTILINE)
        constants.append(definition)
    with tempfile.TemporaryDirectory(dir=scratch) as tmp:
        (Path(tmp) / "process_array_heap.inc").write_text(source.replace(call, summary) + "\n".join(constants) + "\n")
        (Path(tmp) / "process_array_spaces.inc").write_text(spaces)
        command = [esbmc, harness, "-I" + tmp, *flags, "-I" + str(space_dir), "--std", "c++11",
                   "--" + bits, "-DCXXV_WORD_BITS=" + bits, "--overflow-check"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(result.stdout)
        if mode != "proof":
            violation = result.stdout.partition("Violated property:")[2].split("\n\n", 1)[0]
            expected = ("the old array is remembered before any filler store" if mode == "unmarked-old"
                        else "return the supplied filler")
            if "VERIFICATION FAILED" not in result.stdout or expected not in violation:
                sys.exit(1)
        elif result.returncode or "VERIFICATION SUCCESSFUL" not in result.stdout:
            sys.exit(1)


if __name__ == "__main__":
    main()
