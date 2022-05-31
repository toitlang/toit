// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import services.arguments show ArgumentParser

main:
  test_empty
  test_command
  test_rest
  test_option
  test_option_alias
  test_multi_option

test_empty:
  parser := ArgumentParser
  expect_error "Unknown option -f": parser.parse --exit_on_error=false ["-f"]
  expect_error "Unknown option --foo": parser.parse --exit_on_error=false ["--foo"]
  expect_error "Unknown option --foo": parser.parse --exit_on_error=false ["--foo=value"]
  expect_error "Unknown option --foo": parser.parse --exit_on_error=false ["--foo", "value"]

test_command:
  parser := ArgumentParser
  sub1 := parser.add_command "sub1"
  sub2 := parser.add_command "sub2"
  r := parser.parse ["sub1"]
  expect_equals "sub1" r.command
  expect r.rest.is_empty

  r = parser.parse ["sub2"]
  expect_equals "sub2" r.command
  expect r.rest.is_empty

  r = parser.parse ["foo"]
  expect_null r.command
  expect_equals 1 r.rest.size
  expect_equals "foo" r.rest[0]

  sub1.add_flag "foo" --short="f"
  expect_error "Unknown option --foo": parser.parse --exit_on_error=false ["--foo"]
  expect_error "Unknown option -f": parser.parse --exit_on_error=false ["-f"]
  expect_error "Unknown option --foo": parser.parse --exit_on_error=false ["sub2", "--foo"]
  expect_error "Unknown option -f": parser.parse --exit_on_error=false ["sub2", "-f"]

  r = parser.parse ["sub1"]
  expect (not r["foo"])
  r = parser.parse ["sub1", "--foo"]
  expect r["foo"]
  r = parser.parse ["sub1", "-f"]
  expect r["foo"]

test_rest:
  parser := ArgumentParser
  parser.add_option "foo"
  parser.add_option "bar"

  r := parser.parse []
  expect_equals 0 r.rest.size

  r = parser.parse ["x"]
  expect_equals 1 r.rest.size
  expect_equals "x" r.rest[0]

  r = parser.parse ["--foo", "0", "x"]
  expect_equals 1 r.rest.size
  expect_equals "x" r.rest[0]

  r = parser.parse ["--foo=0", "x"]
  expect_equals 1 r.rest.size
  expect_equals "x" r.rest[0]

  r = parser.parse ["x", "--foo", "0"]
  expect_equals 1 r.rest.size
  expect_equals "x" r.rest[0]

  r = parser.parse ["x", "--foo=0"]
  expect_equals 1 r.rest.size
  expect_equals "x" r.rest[0]

  r = parser.parse ["x", "--foo", "0", "--bar=1", "y"]
  expect_equals 2 r.rest.size
  expect_equals "x" r.rest[0]
  expect_equals "y" r.rest[1]

  r = parser.parse ["--", "--bar"]
  expect_equals 1 r.rest.size
  expect_equals "--bar" r.rest[0]

  r = parser.parse ["--foo=0", "--", "--bar"]
  expect_equals 1 r.rest.size
  expect_equals "--bar" r.rest[0]

  r = parser.parse ["x", "--foo=0", "--", "--bar"]
  expect_equals 2 r.rest.size
  expect_equals "x" r.rest[0]
  expect_equals "--bar" r.rest[1]

test_option:
  parser := ArgumentParser
  parser.add_option "x"
  parser.add_option "xy"
  parser.add_option "a" --default="da"
  parser.add_option "ab" --default="dab"
  parser.add_flag "verbose" --short="v"
  parser.add_flag "foobar" --short="foo"

  r := parser.parse []
  expect_null r["x"]
  expect_null r["xy"]
  expect_equals "da" r["a"]
  expect_equals "dab" r["ab"]
  expect (not r["verbose"])
  expect_error "No option named 'v'": r["v"]
  expect (not r["foobar"])
  expect_error "No option named 'foo'": r["foo"]

  r = parser.parse ["--x=1234"]
  expect_equals "1234" r["x"]
  expect_null r["xy"]
  r = parser.parse ["--x", "2345"]
  expect_equals "2345" r["x"]
  expect_null r["xy"]
  r = parser.parse ["--xy=1234"]
  expect_null r["x"]
  expect_equals "1234" r["xy"]
  r = parser.parse ["--xy", "2345"]
  expect_null r["x"]
  expect_equals "2345" r["xy"]

  r = parser.parse ["--a=1234"]
  expect_equals "1234" r["a"]
  expect_equals "dab" r["ab"]
  r = parser.parse ["--a", "2345"]
  expect_equals "2345" r["a"]
  expect_equals "dab" r["ab"]
  r = parser.parse ["--ab=1234"]
  expect_equals "da" r["a"]
  expect_equals "1234" r["ab"]
  r = parser.parse ["--ab", "2345"]
  expect_equals "da" r["a"]
  expect_equals "2345" r["ab"]

  r = parser.parse ["--verbose"]
  expect r["verbose"]
  expect (not r["foobar"])
  r = parser.parse ["-v"]
  expect r["verbose"]
  expect (not r["foobar"])
  r = parser.parse ["--foobar"]
  expect (not r["verbose"])
  expect r["foobar"]
  r = parser.parse ["-foo"]
  expect (not r["verbose"])
  expect r["foobar"]

  expect_error "No value provided for option --x": parser.parse --exit_on_error=false ["--x"]
  expect_error "No value provided for option --xy": parser.parse --exit_on_error=false ["--xy"]
  expect_error "No value provided for option --a": parser.parse --exit_on_error=false ["--a"]
  expect_error "No value provided for option --ab": parser.parse --exit_on_error=false ["--ab"]

  expect_error "Option was provided multiple times: --ab=2": parser.parse --exit_on_error=false ["--ab=0", "--ab=2"]

test_option_alias:
  parser := ArgumentParser
  parser.add_flag "flag" --short="f"
  parser.add_option "evaluate"
  parser.add_alias "evaluate" "e"

  r := parser.parse ["--evaluate", "123"]
  expect_equals "123" r["evaluate"]
  r = parser.parse ["--evaluate=123"]
  expect_equals "123" r["evaluate"]
  expect_error "Unknown option --evaluate123": parser.parse --exit_on_error=false ["--evaluate123"]

  expect_error "No value provided for option -e": parser.parse --exit_on_error=false ["-e"]
  expect_error "Unknown option --e234": parser.parse --exit_on_error=false ["--e234"]

  r = parser.parse ["-e", "234"]
  expect_equals "234" r["evaluate"]
  r = parser.parse ["-e234"]
  expect_equals "234" r["evaluate"]
  r = parser.parse ["-e234"]
  expect_equals "234" r["evaluate"]
  r = parser.parse ["-e345", "-f"]
  expect_equals "345" r["evaluate"]
  expect r["flag"]
  r = parser.parse ["-e" ,"456"]
  expect_equals "456" r["evaluate"]
  r = parser.parse ["-e" ,"456", "--flag"]
  expect_equals "456" r["evaluate"]
  expect r["flag"]

  r = parser.parse ["-e", "234 + 345"]
  expect_equals "234 + 345" r["evaluate"]
  r = parser.parse ["-e234 + 345"]
  expect_equals "234 + 345" r["evaluate"]

test_multi_option:
  parser := ArgumentParser
  parser.add_multi_option "option"
  parser.add_multi_option "multi" --no-split_commas

  r := parser.parse []
  expect_list_equals [] r["option"]
  expect_list_equals [] r["multi"]

  r = parser.parse ["--option", "123"]
  expect_list_equals ["123"] r["option"]
  r = parser.parse ["--option=123"]
  expect_list_equals ["123"] r["option"]
  expect_error "Unknown option --option123": parser.parse --exit_on_error=false ["--option123"]

  r = parser.parse ["--option", "123", "--option=456"]
  expect_list_equals ["123", "456"] r["option"]
  r = parser.parse ["--option=123,456"]
  expect_list_equals ["123", "456"] r["option"]

  r = parser.parse ["--multi", "123"]
  expect_list_equals ["123"] r["multi"]
  r = parser.parse ["--multi=123"]
  expect_list_equals ["123"] r["multi"]
  expect_error "Unknown option --multi123": parser.parse --exit_on_error=false ["--multi123"]

  r = parser.parse ["--multi", "123", "--multi=456"]
  expect_list_equals ["123", "456"] r["multi"]
  r = parser.parse ["--multi=123,456"]
  expect_list_equals ["123,456"] r["multi"]

expect_error name [code]:
  expect_equals
    name
    catch code
