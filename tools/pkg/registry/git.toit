import encoding.yaml
import host.file

import cli.cache show FileStore

import ..git
import ..file-system-view
import ..utils
import ..semantic-version
import .registry

class GitRegistry extends Registry:
  type ::= "git"
  url/string
  ref-hash/string? := null
  content_/FileSystemView? := null

  constructor name .url .ref-hash:
    super name

  content -> FileSystemView:
    if not ref-hash: content_ = sync
    else if not content_: content_ = load_
    return content_

  load_ -> FileSystemView:
    content := cache.get "registry/git/$(url)/$(ref-hash)" : | store/FileStore |
      repository := open-repository url
      pack-data := repository.clone --binary ref-hash
      store.save pack-data

    pack := Pack content ref-hash
    return pack.content

  sync -> FileSystemView:
    repository := open-repository url
    ref-hash = repository.head
    return load_

  to-map -> Map:
    return  {
      "url": url,
      "type": type,
      "ref-hash": ref-hash
    }

  stringify -> string:
    return "$url ($type)"
