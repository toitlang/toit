import host.pipe

main:
  process := pipe.fork "ls" ["ls"]
  process.wait
  /*      ^
  Wait for the process to finish and return the exit-value.
  */
