import cli
import host.directory

import ..pkg
import ..project
import ..semantic-version

project-configuration-from-cli parsed/cli.Parsed:
    return ProjectConfiguration
        --project-root=parsed[OPTION-PROJECT-ROOT]
        --cwd=directory.cwd
        --sdk-version=SemanticVersion parsed[OPTION-SDK-VERSION]
        --auto-sync=parsed[OPTION-AUTO-SYNC]

