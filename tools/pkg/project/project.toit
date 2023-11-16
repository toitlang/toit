import host.file
import host.directory
import cli
import encoding.yaml

import ..registry
import ..error
import ..pkg
import ..git
import ..git.file-system-view

import .package

project-from-cli parsed/cli.Parsed:
  root := parsed[OPTION-PROJECT-ROOT]
  sdk-version := parsed[OPTION-SDK-VERSION]
  if root: return project-from-path root sdk-version
  return project-from-pwd sdk-version

project-from-pwd sdk-version/string -> Project:
  project := Project directory.cwd sdk-version
  if not project.package-file-exists_:
    error """
           Command must be executed in project root.
             Run 'toit.pkg init' first to create a new application here, or
             run with '--$OPTION-PROJECT-ROOT=.'
          """
  return project

project-from-path root/string sdk-version/string:
  return Project root sdk-version

class Project:
  root/string
  package-file/PackageFile? := null
  lock-file/LockFile? := null
  sdk-version/string

  constructor .root .sdk-version:
    if package-file-exists_:
      package-file = PackageFile.from-file package-file-name_
    else:
      package-file = PackageFile package-file-name_

    if lock-file-exits_:
      lock-file = LockFile.load lock-file-name_
    else:
      lock-file = LockFile lock-file-name_

  save:
    package-file.save
    lock-file.save

  install-remote prefix/string remote/RemotePackage:
    repository := open-repository remote.url
    pack := repository.clone remote.ref-hash
    files := pack.content
    new-package-file := PackageFile.from-buffer (files.get PACKAGE-FILE-NAME)
    solve_ new-package-file

  install-local prefix/string path/string:
    new-package-file := PackageFile.from-file "$path/PACKAGE-FILE-NAME"
    solve_ new-package-file



  package-file-name_: return "$root/$PACKAGE-FILE-NAME"
  package-file-exists_ -> bool: return file.is-file package-file-name_

  lock-file-name_: return "$root/$PACKAGE-LOCK-FILE-NAME"
  lock-file-exits_: return file.is-file lock-file-name_


  solve_ new/PackageFile:

PACKAGE-FILE-NAME ::= "package.yaml"
PACKAGE-LOCK-FILE-NAME ::= "package.lock"