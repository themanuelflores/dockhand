#!/bin/bash
# invoke_repo_root.sh

# ==============================================================================
# REQUIRED ENVIRONMENT VARIABLES
# Ensure the following variables are defined in your .env or .envrc file
# (or directly within your 1Password vault items referenced in the env file):
#
# - DOCKER_REGISTRY_SECRET
# - DOCKER_REGISTRY_PREFIX
# - SUBDOMAIN_DOCKER_REGISTRY
# - TLD_DOMAIN_URI_ROOT
# ==============================================================================

echo "🔍 Scanning repository for Dockerfiles..."

DIRS=()

# 1. Explicitly check the Git repository root directory first
if ls ./Dockerfile* 1> /dev/null 2>&1; then
    echo "   -> Found Dockerfile in repository root"
    DIRS+=(".")
fi

# 2. Search all subdirectories (ignoring hidden folders like .git)
# Using -mindepth 2 ensures we only look at child directories since we already handled the root
while IFS= read -r dir; do
    if [ -n "$dir" ]; then
        echo "   -> Found Dockerfile in $dir"
        DIRS+=("$dir")
    fi
done < <(find . -mindepth 2 -not -path '*/\.*' -name "Dockerfile*" -exec dirname {} \; | sort -u)

# 3. Join the array into a comma-separated list for the workhorse
DIR_STRING=$(IFS=,; echo "${DIRS[*]}")

if [ -z "$DIR_STRING" ]; then
    echo "❌ Error: No directories containing Dockerfiles were found in the repository."
    exit 1
fi

echo "📦 Final build contexts: $DIR_STRING"
echo "🔐 Invoking workhorse script via 1Password..."

# Pass the comma-separated directory string to the workhorse script via op run.
#
# Note: If you want to bypass 1Password and supply the arguments manually, 
# you would replace the line below with something like:
# ./build_and_push_images_workhorse.sh -i "$DIR_STRING" -p "my_api_key" -r "pahueikon" -s "registry" -t "gammaepsilon.dev"

op run --env-file=.env -- ./build_and_push_images_workhorse.sh -i "$DIR_STRING"