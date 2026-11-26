#!/usr/bin/env bash
# Lists the tests of a ctest log that started but have not finished.
# Usage: ctest-running.sh LOG
awk '/Start +[0-9]+:/ { n = $2; sub(":", "", n); started[n] = $3 }
     /Test +#[0-9]+:/ { n = $0; sub(/.*Test +#/, "", n); sub(/:.*/, "", n); done[n] = 1 }
     END { for (n in started) if (!(n in done)) print n, started[n] }' "$1"
