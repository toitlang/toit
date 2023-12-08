// TODO(florian): use the cli.Ui class for errors and warnings.

error msg/string:
  print "Error: $msg"
  exit 1

warning msg/string:
  print "Warning: $msg"
