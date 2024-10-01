#!/bin/bash

# A simple bash script to install the packages listed in the package.lock file.
# Typically, 'toit pkg install' would be used to install packages, but since
# the 'toit' executable uses Toit itself, we have a bootstrapping problem.
#
# Relies on a specific format of the package.lock file. For example, there
# must not be any comments in the file.

# The package dir is the first argument or ".packages" if not provided.
PACKAGE_DIR="${1:-.packages}"

# Function to extract values from YAML.
extract_value() {
    local key=$1
    local section=$2
    echo "$section" | awk -F': ' '/'$key':/{print $2}' | sed "s/^['\"]//;s/['\"]$//"
}

# Read the YAML file.
yaml_file="package.lock"

# Create the .packages directory if it doesn't exist.
mkdir -p "$PACKAGE_DIR"

# Extract the packages section.
# Start with a line that starts with "packages:" and end with a line that
# doesn't start with a space.
packages_section=$(sed -n '/^packages:/,/^[^ ]/p' "$yaml_file")

# Process each package.
echo "$packages_section" | while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]{2}[^[:space:]]+: ]]; then
        package_name=$(echo "$line" | sed 's/:[[:space:]]*$//' | sed 's/^[[:space:]]*//')

        # Extract the entire section for this package.
        # The package_details may have other packages as well, as long
        # as this package (the one named 'package_name') is first.
        # As before: use 'sed' to take anything starting with "  $package_name:" and
        # ends with something that doesn't have 4 spaces.
        package_details=$(echo "$packages_section" | sed -n "/  $package_name:/,/^  [^ ]/p")

        url=$(extract_value "url" "$package_details")
        version=$(extract_value "version" "$package_details")
        hash=$(extract_value "hash" "$package_details")

        if [ -n "$url" ] && [ -n "$version" ] && [ -n "$hash" ]; then
            target_dir="$PACKAGE_DIR/$url/$version"
            if [ -d "$target_dir" ]; then
                continue
            fi
            echo "Cloning $package_name..."
            mkdir -p "$target_dir"
            if git clone "https://$url" "$target_dir" 2>/dev/null; then
                (
                    cd "$target_dir"
                    git checkout "$hash" --quiet
                )
                echo "Successfully cloned $package_name (version $version, hash $hash)"
            else
                echo "Failed to clone $package_name"
                rm -rf "$target_dir"
            fi
        else
            echo "Skipping $package_name due to missing information"
        fi
    fi
done
