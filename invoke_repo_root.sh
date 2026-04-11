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

echo "🔍 Scanning entire repository for Dockerfiles..."

# Find all directories containing a Dockerfile (ignoring hidden paths like .git)
# Deduplicate the directories and join them with commas.
DIRS=$(find . -not -path '*/\.*' -name "Dockerfile*" -exec dirname {} \; | sort -u | paste -sd, -)

if [ -z "$DIRS" ]; then
    echo "❌ Error: No directories containing Dockerfiles were found in the repository."
    exit 1
fi

echo "📦 Found Dockerfile contexts in: $DIRS"
echo "🔐 Invoking workhorse script via 1Password..."

# Pass the comma-separated directory string to the workhorse script via op run.
#
# Note: If you want to bypass 1Password and supply the arguments manually, 
# you would replace the line below with something like:
# ./build_and_push_workhorse.sh -i "$DIRS" -p "my_api_key" -r "pahueikon" -s "registry" -t "gammaepsilon.dev"

op run --env-file=.env -- ./build_and_push_images_workhorse.sh -i "$DIRS"