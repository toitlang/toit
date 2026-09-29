// Copyright (C) 2026 Toit contributors.
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

import cli
import encoding.json
import host.file
import host.pipe
import io
import uart

import .analysis
import .capture
import .names

main args:
  exception := catch:
    // All output is JSON, so don't offer the generic UI options.
    build-command.run args --add-ui-help=false
  if exception:
    output { "error": "$exception" }
    exit 1

build-command -> cli.Command:
  root := cli.Command "memory-inspector"
      --help="""
        Analyzes memory captures of Toit devices.

        A Toit program creates a capture with 'system.capture-memory'. The
          capture pauses all processes and prints their heaps and the
          allocations of the system heap as "#TMC" lines on the console.
          Record them with the 'record' command, or save the console output
          in any other way (for example with 'jag monitor').

        All analysis commands print JSON. Class, field, and global names are
          taken from the snapshots of the programs. They are found by the
          program's UUID in the given snapshot files and directories.
        """

  root.add (cli.Command "record"
      --help="""
        Records a capture from a serial port.

        Waits for the device to print a capture and writes the capture
          lines to the output file. Other console output is printed on stderr.
        """
      --options=[
        cli.Option "port" --short-name="p" --required
            --help="The serial port of the device.",
        cli.OptionInt "baud-rate" --short-name="b" --default=115200
            --help="The baud rate of the serial port.",
        cli.OptionInt "timeout" --default=120
            --help="The number of seconds to wait for a complete capture.",
      ]
      --rest=[
        cli.OptionPath "output" --required
            --help="The file to write the capture to.",
      ]
      --run=:: record it)

  capture-option := cli.OptionPath "capture" --required
      --help="A file that contains a capture, for example a console log."
  process-option := cli.OptionInt "process"
      --help="The id of the process. Defaults to all processes."
  limit-option := cli.OptionInt "limit" --default=20
      --help="The maximum number of results."
  snapshot-options := [
    cli.OptionPath "snapshot" --short-name="s" --multi
        --help="A snapshot of a program in the capture.",
    cli.OptionPath "envelope" --short-name="e" --multi
        --help="A firmware envelope. Uses the snapshots of its containers.",
    cli.OptionPath "snapshot-dir" --multi
        --help="A directory with <uuid>.snapshot files. Defaults to the directories of the Toit and Jaguar tools.",
  ]

  root.add (cli.Command "summary"
      --help="""
        Summarizes where the memory is used.

        Shows the size of the system heaps, the allocations of the system heap
          by owner (Toit processes own the chunks of their heaps and the
          external content of their objects; other blocks are grouped by their
          malloc tag), and for each process the live and unreachable bytes of
          its heap and the classes that use the most memory.
        """
      --options=snapshot-options
      --rest=[capture-option]
      --run=:: | invocation/cli.Invocation |
        output ((load-analysis invocation).summary))

  root.add (cli.Command "census"
      --help="""
        Lists the classes of the objects in the heap of a process, with the
          number of objects, their bytes on the heap, their external bytes (in
          the system heap), and how many of them are reachable from the roots.
        """
      --options=snapshot-options + [process-option, limit-option]
      --rest=[capture-option]
      --run=:: | invocation/cli.Invocation |
        analysis := load-analysis invocation
        limit := invocation["limit"]
        output (for-processes analysis invocation: | process/ProcessInfo |
          classes := analysis.census process
          classes[..min limit classes.size]))

  return root

output value/any -> none:
  print (json.stringify value)

load-capture path/string -> Capture:
  return Capture.parse (file.read-contents path).to-string-non-throwing

load-names invocation/cli.Invocation -> Names:
  dirs := invocation["snapshot-dir"]
  if dirs.is-empty: dirs = default-snapshot-dirs
  return Names
      --snapshots=invocation["snapshot"]
      --envelopes=invocation["envelope"]
      --snapshot-dirs=dirs

load-analysis invocation/cli.Invocation -> Analysis:
  return Analysis (load-capture invocation["capture"]) (load-names invocation)

/**
Calls $block for the process given by the "process" option, or for all
  processes. Returns a list of maps with the process id and the result.
*/
for-processes analysis/Analysis invocation/cli.Invocation [block] -> List:
  id := invocation["process"]
  processes := id ? [analysis.process-by-id id] : analysis.capture.processes
  return processes.map: | process/ProcessInfo |
    { "process": process.id, "result": block.call process }

record invocation/cli.Invocation -> none:
  port := uart.HostPort invocation["port"] --baud-rate=invocation["baud-rate"]
  lines := []
  pending := io.Buffer
  done := false
  catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
    with-timeout --ms=(invocation["timeout"] * 1000):
      while not done:
        data := port.in.read
        if not data: break
        pending.write data
        while true:
          bytes := pending.bytes
          newline := bytes.index-of '\n'
          if newline < 0: break
          line := bytes[..newline].to-string-non-throwing.trim
          remaining := bytes[newline + 1..].copy
          pending.clear
          pending.write remaining
          decoded := null
          catch: decoded = decode-line line
          if not decoded:
            pipe.print-to-stderr line
            continue
          // Start at the first record of a capture.
          if decoded[0] == 0: lines.clear
          else if lines.is-empty: continue
          lines.add line[line.index-of LINE-PREFIX..]
          if decoded[1][0] == END-RECORD:
            done = true
            break
  port.close
  file.write-contents --path=invocation["output"] ((lines.join "\n") + "\n")
  capture := Capture.parse (lines.join "\n")
  output {
    "output": invocation["output"],
    "records": lines.size,
    "complete": capture.problems.is-empty,
    "problems": capture.problems,
  }
