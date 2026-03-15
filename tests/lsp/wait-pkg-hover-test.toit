import host.pipe

foo process/pipe.Process:
  process.wait
  /*      ^
  Wait for the process to finish and return the exit-value.
  */

main:
