// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.url

main:
  test_url_encode
  test_url_decode
  test_query_string

test_url_encode:
  expect_equals "foo" (url.encode "foo")
  expect_equals "-_.~abcABC012" (url.encode "-_.~abcABC012")
  expect_equals "%20" (url.encode " ").to_string
  expect_equals "%25" (url.encode "%").to_string
  expect_equals "%2B" (url.encode "+").to_string
  expect_equals "%26" (url.encode "&").to_string
  expect_equals "%3D" (url.encode "=").to_string
  expect_equals "%00%01%02%03%04" (url.encode (ByteArray 5: it)).to_string
  expect_equals "%F0%F1%F2%F3%F4" (url.encode (ByteArray 5: 0xf0 + it)).to_string
  expect_equals "%F1sh" (url.encode #[0xf1, 's', 'h']).to_string
  expect_equals "-%E2%98%83-" (url.encode "-☃-").to_string
  expect_equals "%E2%82%AC25%2C-" (url.encode "€25,-").to_string

test_url_decode:
  expect_equals "foo" (url.decode "foo")
  expect_equals "-_.~abcABC012" (url.decode "-_.~abcABC012")
  expect_equals "Søen så sær ud" (url.decode "Søen så sær ud")  // Postel.
  expect_equals " " (url.decode "%20").to_string
  expect_equals "%" (url.decode "%25").to_string
  expect_equals "+" (url.decode "+")            // Doesn't treat '+' specially.
  expect_equals "&" (url.decode "&")            // Doesn't treat '&' specially.
  expect_equals "=" (url.decode "=")            // Doesn't treat '=' specially.
  expect_equals "+" (url.decode "%2B").to_string
  expect_equals "&" (url.decode "%26").to_string
  expect_equals "=" (url.decode "%3D").to_string
  expect_equals #[0, 1, 2, 3, 4] (url.decode (ByteArray 5: it))
  expect_equals #[0, 1, 2, 3, 4] (url.decode "%00%01%02%03%04")
  expect_equals #[0xf0, 0xf1, 0xf2] (url.decode (ByteArray 3: 0xf0 + it))
  expect_equals #[0xf0, 0xf1, 0xf2] (url.decode "%F0%F1%F2")
  expect_equals #[0xf0, 0xf1, 0xf2] (url.decode "%f0%f1%f2")  // Lower case.
  expect_equals "%F1sh" (url.encode #[0xf1, 's', 'h']).to_string
  expect_equals "-☃-" (url.decode "-%E2%98%83-").to_string
  expect_equals "€25,-" (url.decode "%E2%82%AC25%2C-").to_string

test_query_string:
  qs := url.QueryString.parse "/foo?x=y"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "?x=y"
  expect_equals "" qs.resource
  expect_structural_equals { "x": "y" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&w=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y", "w": "z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&x=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": ["y", "z"] } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&x=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": ["y", "z"] } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y=z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y=z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse ""
  expect_equals "" qs.resource
  expect_structural_equals {:} qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x="
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=&y=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "", "y": "z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?=x&y=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "": "x", "y": "z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x&y=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "", "y": "z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&=z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y", "": "z" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&y"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y", "y": "" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "http://quux.com/foo?x=y"
  expect_equals "http://quux.com/foo" qs.resource
  expect_structural_equals { "x": "y" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "http://quux%20.com/foo"
  expect_equals "http://quux .com/foo" qs.resource
  expect_structural_equals {:} qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "hest": "fisk" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk%20er%20sundt"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "hest": "fisk er sundt" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk%20er%20sundt"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "hest": "fisk er sundt" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest%3dlotte=fisk"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "hest=lotte": "fisk" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk%26jumbo=bog"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "hest": "fisk&jumbo=bog" } qs.parameters
  expect_equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y#z"
  expect_equals "/foo" qs.resource
  expect_structural_equals { "x": "y" } qs.parameters
  expect_equals "z" qs.fragment

  qs = url.QueryString.parse "/foo=y#z"
  expect_equals "/foo=y" qs.resource
  expect_structural_equals {:} qs.parameters
  expect_equals "z" qs.fragment

  qs = url.QueryString.parse "/foo=y#z?y"
  expect_equals "/foo=y" qs.resource
  expect_structural_equals {:} qs.parameters
  expect_equals "z?y" qs.fragment

  qs = url.QueryString.parse "/foo=y#z?y"
  expect_equals "/foo=y" qs.resource
  expect_structural_equals {:} qs.parameters
  expect_equals "z?y" qs.fragment

  qs = url.QueryString.parse "http://quux%20.com/foo#%20bar"
  expect_equals "http://quux .com/foo" qs.resource
  expect_structural_equals {:} qs.parameters
  expect_equals " bar" qs.fragment
