import host.file
import host.directory
import cli
import cli.cache show Cache
import encoding.yaml
import system

import ..registry
import ..error
import ..pkg
import ..git
import ..semantic-version

import .package
import .lock

class ProjectConfiguration:
  project-root_/string?
  cwd_/string
  sdk-version/SemanticVersion

  constructor.private_ .project-root_ .cwd_ .sdk-version auto-sync/bool:
    if auto-sync:
      registries.sync

  constructor.from-cli parsed/cli.Parsed:
    return ProjectConfiguration.private_
        parsed[OPTION-PROJECT-ROOT]
        directory.cwd
        SemanticVersion parsed[OPTION-SDK-VERSION]
        parsed[OPTION-AUTO-SYNC]

  root -> string:
    return project-root_ ? project-root_ : cwd_

  package-file-exists -> bool:
    return file.is_file (PackageFile.file-name root)

  lock-file-exists -> bool:
    return file.is_file (LockFile.file-name root)

  verify:
    if project-root_ == null and (not package-file-exists or not lock-file-exists):
      error """
            Command must be executed in project root.
              Run 'toit.pkg init' first to create a new application here, or
              run with '--$OPTION-PROJECT-ROOT=.'
            """
  static CACHE-DIR ::= ".toit-pkg-cache"


class Project:
  config/ProjectConfiguration
  package-file/ProjectPackageFile? := null
  lock-file/LockFile? := null

  static PACKAGES-CACHE ::= ".packages"

  constructor .config/ProjectConfiguration --empty-lock-file/bool=false:
    if config.package-file-exists:
      package-file = ProjectPackageFile.load this
    else:
      package-file = ProjectPackageFile.new this

    if config.lock-file-exists:
      lock-file = LockFile.load package-file
    else if empty-lock-file:
      lock-file = LockFile package-file

    cache = Cache --app-name="toit-pkg"

  root -> string:
    return config.root

  sdk-version -> SemanticVersion:
    return config.sdk-version

  save:
    package-file.save
    lock-file.save

  install-remote prefix/string remote/RemotePackage:
    package-file.add-remote-dependency prefix remote.url "^$remote.version"
    solve_
    save

  install-local prefix/string path/string:
    package-file.add-local-dependency prefix path
    solve_
    save

  uninstall prefix/string:
    package-file.remove-dependency prefix
    lock-file.update --remove-prefix=prefix
    save

  update:
    solve_
    save

  install:
    lock-file.install

  clean:
    repository-packages := lock-file.repository-packages
    url-to-version := {:}
    repository-packages.do: | package/RepositoryPackage |
      url-to-version[package.url] = package.version

    urls := directory.DirectoryStream packages-cache-dir
    while url := urls.next:
      if not url-to-version.contains url:
        directory.rmdir --recursive "$packages-cache-dir/$url"
      else:
        versions := directory.DirectoryStream "$packages-cache-dir/$url"
        while version := versions.next:
          if not url-to-version[url].contains version:
            directory.rmdir --recursive "$packages-cache-dir/$url/$version"
        versions.close
    urls.close

  packages-cache-dir:
    return "$config.root/$PACKAGES-CACHE"

  solve_ :
    lock-file = package-file.solve

  cached-repository-dir_ url/string version/SemanticVersion -> string:
    return "$packages-cache-dir/$url/$version"

  ensure-downloaded url/string version/SemanticVersion:
    cached-repository-dir := cached-repository-dir_ url version
    repo-toit-git-path := "$cached-repository-dir/.toit-git"
    if file.is_file repo-toit-git-path : return
    directory.mkdir --recursive cached-repository-dir
    description := registries.retrieve-description url version
    repository := Repository url
    pack := repository.clone description.ref-hash
    pack.expand cached-repository-dir
    file.write_content description.ref-hash --path=repo-toit-git-path

  load-package-package-file url/string version/SemanticVersion:
    cached-repository-dir := cached-repository-dir_ url version
    return ExternalPackageFile "$cached-repository-dir"

  load-local-package-file path/string -> ExternalPackageFile:
    return ExternalPackageFile "$root/$path"

main:
  config := ProjectConfiguration.private_ "tmp2" directory.cwd (SemanticVersion system.vm-sdk-version) false
  print system.vm-sdk-version
  project := Project config
  project.solve_
  print project.lock-file.to-map_
  print (yaml.stringify project.lock-file.to-map_)