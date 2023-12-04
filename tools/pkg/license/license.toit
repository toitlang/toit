import .data

validate-license-id license/string -> bool:
  return LICENSE_IDS.contains license

cannonicalize-license license-text -> string:
  // Remove all spacaes and lines beginning with 'Copyright' from license-text
  lines := license-text.split "\n"
  lines.filter --in-place: not it.starts-with "Copyright"
  lines.map --in-place: it.replace " " ""
  return lines.join ""

guess-license license-text -> string?:
  canonicalized := cannonicalize-license license-text
  KNOWN_LICENSES.do: | license-id text |
    canonicalized-known := cannonicalize-license text
    if canonicalized-known.starts-with canonicalized or
       canonicalized-known.ends-with canonicalized:
      return license-id
  return null
