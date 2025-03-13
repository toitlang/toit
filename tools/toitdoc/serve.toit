// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import certificate-roots
import cli show Cli DirectoryStore
import desktop
import host.file
import host.pipe
import http
import http.server
import log
import net
import system

TOITDOC_WEB_VERSION ::= "v1.0.0"
TOITDOC_WEB_URI ::= "https://github.com/toitware/web-toitdocs/releases/download/$TOITDOC_WEB_VERSION/build.tar.gz"

get-content-type-from-extension path/string -> string:
  last-dot := path.index-of --last "."
  if last-dot == -1:
    return "application/octet-stream"
  extension := path[last-dot + 1..]
  if extension == "html": return "text/html"
  if extension == "css": return "text/css"
  if extension == "js": return "application/javascript"
  if extension == "json": return "application/json"
  if extension == "png": return "image/png"
  if extension == "svg": return "image/svg+xml"
  if extension == "ico": return "image/x-icon"
  if extension == "txt": return "text/plain"
  if extension == "map": return "application/json"
  if extension == "woff": return "font/woff"
  return "application/octet-stream"

serve docs-path/string --port/int --open-browser/bool --cli/Cli:
  cache := cli.cache
  ui := cli.ui

  web-dir := cache.get-directory-path "toitdoc/$TOITDOC-WEB-VERSION": | store/DirectoryStore |
    store.with-tmp-directory: | dir/string |
      if system.platform == system.PLATFORM-WINDOWS:
        ui.abort "Serving toitdocs is not supported on Windows."
      certificate-roots.install-all-trusted-roots
      network := net.open
      client := http.Client network
      response := client.get --uri=TOITDOC-WEB-URI
      if response.status-code != 200:
        ui.abort "Failed to download web-toitdocs."
      local-path := "$dir/build.tar.gz"
      local := file.Stream.for-write local-path
      try:
        local.out.write-from response.body
      finally:
        local.close
        response.body.drain
        client.close

      // TODO(florian): implement tar.gz extraction in Toit.
      pipe.run-program "tar" "-xzf" local-path "-C" dir
      file.delete local-path

      store.move dir

  network := net.open
  // Listen on a free port.
  tcp_socket := network.tcp_listen port
  url := "http://localhost:$tcp_socket.local_address.port/"
  ui.emit --result
    --text=:
      ui.wants-human
          ? "Serving toitdocs on $url."
          : url
    --structured=: { "url": url }

  if open-browser: desktop.open-browser url

  // TODO(florian): we want to base the logger on the UI.
  server := http.Server --max-tasks=20 --logger=(log.default.with-level log.WARN_LEVEL)
  server.listen tcp_socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
    resource := request.query.resource
    resource-path/string := ?
    if resource == "/":
      resource-path = "$web-dir/index.html"
    else if resource == "/toitdoc.json":
      resource-path = docs-path
    else:
      resource-path = "$web-dir$resource"

    if not file.is-file resource-path:
      resource-path = "$web-dir/index.html"

    ui.emit --debug "Serving $resource-path."
    content := file.read-contents resource-path
    content-type := get-content-type-from-extension resource-path
    content-size := content.size
    writer.headers.set "Content-Type" content-type
    writer.headers.set "Content-Length" content-size.stringify
    writer.out.write content
    writer.close

