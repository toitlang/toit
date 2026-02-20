import host.pipe

main:
  pipe.fork "ls" ["ls"]
/*     ^
Forks a process.

Attaches the given $stdin, $stdout, $stderr streams to the corresponding
streams of the child process. If a stream is null, then it is inherited.
Use $(Stream.constructor --parent-to-child) or $(Stream.constructor --child-to-parent)
to create a fresh pipe.
Alternatively, a pipe can be created using the $create-stdin,
$create-stdout, and $create-stderr flags. In this case use $Process.stdin,
$Process.stdout, and $Process.stderr to access the streams.
The $stdin and $create-stdin (respectively $stdout and $create-stdout,
$stderr and $create-stderr) arguments are mutually exclusive.

To avoid zombies you must either cal $Process.wait-ignore or $Process.wait.

The $file-descriptor-3 and $file-descriptor-4 can be used to pass streams as
open file descriptors 3 and/or 4 to the child process.

The $environment variable, if given, must be a map where the keys are strings and
the values strings or null, where null indicates that the variable should be
unset in the child process.

If you override the PATH environment variable, but set the $use-path
flag, the new value of PATH will be used to find the executable.
*/
