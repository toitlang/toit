import cli
import host.directory

import ..pkg
import ..project
import ..semantic-version

project-configuration-from-cli invocation/cli.Invocation -> ProjectConfiguration:
  return ProjectConfiguration
      --project-root=invocation[OPTION-PROJECT-ROOT]
      --cwd=directory.cwd
      --sdk-version=SemanticVersion.parse invocation[OPTION-SDK-VERSION]
      --auto-sync=invocation[OPTION-AUTO-SYNC]

