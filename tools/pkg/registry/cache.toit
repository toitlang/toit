import .description
import ..file-system-view
import ..semantic-version
import encoding.yaml

/**
A cache of registry descriptions.

This class collects all descriptions in a registry and builds and groups them by url.
*/
class DescriptionUrlCache:
  cache_/Map := {:} // url -> DescriptionVersionCache

  constructor content/FileSystemView:
    recurse_ content

  all-descriptions -> List:
    result := []
    cache_.values.do: | versions/DescriptionVersionCache |
      result.add-all versions.all-descriptions
    return result

  retrieve-description url/string version/SemanticVersion -> Description?:
    version-cache/DescriptionVersionCache? := cache_.get url
    return version-cache and version-cache.get version

  retrieve-versions url/string -> List?:
    version-cache/DescriptionVersionCache? := cache_.get url
    return version-cache and version-cache.all-versions


  /**
  Returns a map, mapping urls to lists of descriptions.
  */
  search url-suffix/string version-prefix/string? -> Map:
    result := {:}
    cache_.do: | url/string version-cache/DescriptionVersionCache |
      if url.ends-with url-suffix:
        if not version-prefix:
          result[url] = version-cache.all-descriptions
        else:
          result[url] = version-cache.filter version-prefix
    return result

  recurse_ content/FileSystemView:
    content.list.do: | name/string entry |
      if entry is FileSystemView:
        recurse_ entry
      else if name == Description.DESCRIPTION-FILE-NAME:
        description := Description (yaml.decode (content.get entry))
        e := catch:
          add_ description
        if e:
          print "Failed to add $description.url@$description.content[Description.VERSION-KEY_] to index"

  add_ description/Description:
    (cache_.get description.url --init=(: DescriptionVersionCache)).add_ description

  operator [] url/string -> DescriptionVersionCache?:
    return cache_.get url


/**
A cache of registry descriptions for a url.

This class collects all descriptions for the same url and stores them by version.
*/
class DescriptionVersionCache:
  cache_/Map := {:} // version -> description

  constructor:

  all-descriptions -> List:
    return cache_.values

  get version/SemanticVersion -> Description?:
    return cache_.get version

  all-versions -> List?:
    return cache_.keys

  filter version-prefix/string -> List:
    result := []
    cache_.do: | version/SemanticVersion description |
      if version.stringify.starts-with version-prefix:
        result.add description
    return result

  add_ description/Description:
    cache_[description.version] = description