#!/bin/bash

for (( i = 1000; i < 10000; i++));
do
  # Get the exit code of the last command
  echo $i
  MBEDTLS_CALLOC_COUNTER=$i toit.run tests/tls2-test.toit
  exit_code=$?
  if (( $exit_code != 0 && $exit_code != 1 )); then
    echo "Failed with exit code $exit_code"
    exit $exit_code
  fi
done

