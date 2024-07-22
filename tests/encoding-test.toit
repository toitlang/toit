// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.url

main:
  test-url-encode
  test-url-decode
  test-query-string

test-url-encode:
  expect-equals "foo" (url.encode "foo")
  expect-equals "-_.~abcABC012" (url.encode "-_.~abcABC012")
  expect-equals "%20" (url.encode " ")
  expect-equals "%25" (url.encode "%")
  expect-equals "%2B" (url.encode "+")
  expect-equals "%26" (url.encode "&")
  expect-equals "%3D" (url.encode "=")
  expect-equals "%00%01%02%03%04" (url.encode (ByteArray 5: it))
  expect-equals "%F0%F1%F2%F3%F4" (url.encode (ByteArray 5: 0xf0 + it))
  expect-equals "%F1sh" (url.encode #[0xf1, 's', 'h'])
  expect-equals "-%E2%98%83-" (url.encode "-☃-")
  expect-equals "%E2%82%AC25%2C-" (url.encode "€25,-")

test-url-decode:
  expect-equals "foo" (url.decode "foo")
  expect-equals "-_.~abcABC012" (url.decode "-_.~abcABC012")
  expect-equals "Søen så sær ud" (url.decode "Søen så sær ud")  // Postel.
  expect-equals " " (url.decode "%20").to-string
  expect-equals "%" (url.decode "%25").to-string
  expect-equals "+" (url.decode "+")            // Doesn't treat '+' specially.
  expect-equals "&" (url.decode "&")            // Doesn't treat '&' specially.
  expect-equals "=" (url.decode "=")            // Doesn't treat '=' specially.
  expect-equals "+" (url.decode "%2B").to-string
  expect-equals "&" (url.decode "%26").to-string
  expect-equals "=" (url.decode "%3D").to-string
  expect-equals #[0, 1, 2, 3, 4] (url.decode-binary (ByteArray 5: it).to-string)
  expect-equals #[0, 1, 2, 3, 4] (url.decode-binary "%00%01%02%03%04")
  expect-equals #[0xf0, 0xf1, 0xf2] (url.decode-binary "%F0%F1%F2")
  expect-equals #[0xf0, 0xf1, 0xf2] (url.decode-binary "%f0%f1%f2")  // Lower case.
  expect-equals #[0xf1, 's', 'h'] (url.decode-binary "%F1sh")
  expect-equals "-☃-" (url.decode "-%E2%98%83-")
  expect-equals "€25,-" (url.decode "%E2%82%AC25%2C-")

test-query-string:
  qs := url.QueryString.parse "/foo?x"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?+x"
  expect-equals "/foo" qs.resource
  expect-structural-equals { " x": "" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?+x+"
  expect-equals "/foo" qs.resource
  expect-structural-equals { " x ": "" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?++x+y++"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "  x y  ": "" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "?x=y"
  expect-equals "" qs.resource
  expect-structural-equals { "x": "y" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&w=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y", "w": "z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&x=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": ["y", "z"] } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&x=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": ["y", "z"] } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y=z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y=z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse ""
  expect-equals "" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x="
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=+"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": " " } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=++"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "  " } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=&y=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "", "y": "z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?=x&y=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "": "x", "y": "z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x&y=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "", "y": "z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&=z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y", "": "z" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y&y"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y", "y": "" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "http://quux.com/foo?x=y"
  expect-equals "http://quux.com/foo" qs.resource
  expect-structural-equals { "x": "y" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "http://quux%20.com/foo"
  expect-equals "http://quux .com/foo" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest": "fisk" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk%20er%20sundt"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest": "fisk er sundt" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk+er+sundt"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest": "fisk er sundt" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest%20fisk=godt"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest fisk": "godt" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest+fisk=godt"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest fisk": "godt" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest%3dlotte=fisk"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest=lotte": "fisk" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?hest=fisk%26jumbo=bog"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "hest": "fisk&jumbo=bog" } qs.parameters
  expect-equals "" qs.fragment

  qs = url.QueryString.parse "/foo?x=y#z"
  expect-equals "/foo" qs.resource
  expect-structural-equals { "x": "y" } qs.parameters
  expect-equals "z" qs.fragment

  qs = url.QueryString.parse "/foo=y#z"
  expect-equals "/foo=y" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals "z" qs.fragment

  qs = url.QueryString.parse "/foo=y#z?y"
  expect-equals "/foo=y" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals "z?y" qs.fragment

  qs = url.QueryString.parse "/foo=y#z?y"
  expect-equals "/foo=y" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals "z?y" qs.fragment

  qs = url.QueryString.parse "http://quux%20.com/foo#%20bar"
  expect-equals "http://quux .com/foo" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals " bar" qs.fragment

  qs = url.QueryString.parse "http://quux+.com/foo#+bar"
  expect-equals "http://quux+.com/foo" qs.resource
  expect-structural-equals {:} qs.parameters
  expect-equals "+bar" qs.fragment

  qs = url.QueryString.parse "http://www.example.com/fish+chips?peas=mushy"
  expect-equals "http://www.example.com/fish+chips" qs.resource
  expect-structural-equals { "peas": "mushy"} qs.parameters
  expect-equals "" qs.fragment
