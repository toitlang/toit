import host.file
import host.directory
import cli
import encoding.yaml
import system

import ..registry
import ..error
import ..pkg
import ..git
import ..semantic-version

import .package
import .lock

project-from-cli parsed/cli.Parsed:
  root := parsed[OPTION-PROJECT-ROOT]
  sdk-version := SemanticVersion parsed[OPTION-SDK-VERSION]
  if root: return project-from-path root sdk-version
  return project-from-pwd sdk-version

project-from-pwd sdk-version/SemanticVersion -> Project:
  project := Project directory.cwd sdk-version
  if not project.package-file-exists_:
    error """
           Command must be executed in project root.
             Run 'toit.pkg init' first to create a new application here, or
             run with '--$OPTION-PROJECT-ROOT=.'
          """
  return project

project-from-path root/string sdk-version/SemanticVersion:
  return Project root sdk-version

class Project:
  root/string
  package-file/ProjectPackageFile? := null
  sdk-version/SemanticVersion
  lock-file/LockFile? := null

  static PACKAGES-CACHE ::= ".packages"

  constructor .root .sdk-version:
    if package-file-exists_:
      package-file = ProjectPackageFile.load this
    else:
      package-file = ProjectPackageFile.new this

  save:
    package-file.save
    lock-file.save root

  install-remote prefix/string remote/RemotePackage:
    package-file.add-remote-dependency prefix remote.url "^$remote.version"
    solve_

  install-local prefix/string path/string:
    package-file.add-local-dependency prefix path
    solve_

  package-file-name_:
    return "$root/$PackageFile.FILE-NAME"

  package-file-exists_ -> bool:
    return file.is-file package-file-name_

  packages-cache-dir:
    return "$root/$PACKAGES-CACHE"

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

main:
  print system.vm-sdk-version
  project := Project "tmp2" (SemanticVersion system.vm-sdk-version)
  project.solve_
  print project.lock-file.to-map
  print (yaml.stringify project.lock-file.to-map)