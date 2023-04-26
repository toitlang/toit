import host.pipe
import monitor

main:
  outputs_seen := {}
  1_000_000.repeat:
    fork_env := {
        "MBEDTLS_MALLOC_FAIL_COUNTER": "$it",
    }
    fds := pipe.fork
        true  // Use PATH.
        null  // Inherit stdin.
        pipe.PIPE_CREATED  // Create stdout.
        pipe.PIPE_CREATED  // Create stderr.
        "toit.run"
        ["toit.run", "tls_connect.toit"]
        --environment=fork_env
    semaphore := monitor.Semaphore
    lines := []
    task:: tail fds[1] lines semaphore  // stdout.
    task:: tail fds[2] lines semaphore  // stderr.
    semaphore.down
    semaphore.down
    output := lines.join "\n"
    exit_code := pipe.wait_for fds[3]
    if exit_code == 0:
      exit 0
    if not outputs_seen.contains output:
      outputs_seen.add output
      print ""
      print "MBEDTLS_MALLOC_FAIL_COUNTER=$it"
      print
          lines[0].starts_with "EXCEPTION error." ? lines[1] : lines[0]


tail fd lines/List semaphore/monitor.Semaphore -> none:
  previous := #[]
  while data := fd.read:
    data = previous + data
    while data != #[]:
      index := data.index_of '\n'
      if index == -1:
        previous = data
        data = #[]
      else:
        line := data[0..index].to_string
        lines.add line
        data = data[index + 1..]
  fd.close
  if previous != #[]:
    lines.add previous.to_string
  semaphore.up
