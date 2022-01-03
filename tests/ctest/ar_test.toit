// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import host.pipe
import host.directory
import host.file
import host.tar show *
import ..ar_test as toit_ar_test

do_ctest exe_dir tmp_dir file_mapping --in_memory=false:
  tmp_path := "$tmp_dir/c_generated.a"
  generator_path := "$exe_dir/ar_generator"
  args := [
    generator_path,
    tmp_path,
  ]
  if in_memory: args.add "--memory"

  pipes := pipe.fork
      true                // use_path
      pipe.PIPE_CREATED   // stdin
      pipe.PIPE_INHERITED // stdout
      pipe.PIPE_INHERITED // stderr
      generator_path
      args
  to := pipes[0]
  pid  := pipes[3]
  tar := Tar to
  file_mapping.do: |name content|
    tar.add name content
  tar.close --no-close_writer
  to.close
  pipe.wait_for pid
  return file.read_content tmp_path

main args:
  // FreeRTOS doesn't run c tests.
  if platform == "FreeRTOS": return

  exe_dir := args[0]
  toit_ar_test.run_tests: |tmp_dir file_mapping|
    do_ctest exe_dir tmp_dir file_mapping
  toit_ar_test.run_tests: |tmp_dir file_mapping|
    do_ctest exe_dir tmp_dir file_mapping --in_memory
