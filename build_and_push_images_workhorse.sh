#!/bin/bash
# build_and_push_workhorse.sh

IMAGE_DIRECTORIES=""
REGISTRY_PASSWORD=""
REGISTRY_PREFIX=""
SUBDOMAIN=""
TLD=""

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -i|--image-directories) IMAGE_DIRECTORIES="$2"; shift ;;
        -p|--password) REGISTRY_PASSWORD="$2"; shift ;;
        -r|--registry-prefix) REGISTRY_PREFIX="$2"; shift ;;
        -s|--subdomain) SUBDOMAIN="$2"; shift ;;
        -t|--tld) TLD="$2"; shift ;;
        *) echo "❌ Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$IMAGE_DIRECTORIES" ]; then
    echo "❌ Error: --image-directories (-i) must be provided with a comma-separated list of paths."
    exit 1
fi

# ==============================================================================
# FALLBACK LOGIC
# If CLI arguments were not provided, fallback to the environment variables 
# injected by `op run` or loaded via an .env file.
# ==============================================================================
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-$DOCKER_REGISTRY_SECRET}"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-$DOCKER_REGISTRY_PREFIX}"
SUBDOMAIN="${SUBDOMAIN:-$SUBDOMAIN_DOCKER_REGISTRY}"
TLD="${TLD:-$TLD_DOMAIN_URI_ROOT}"

# ==============================================================================
# VALIDATION
# Explicitly identify and report any missing configuration parameters.
# ==============================================================================
MISSING_PARAMS=()

[ -z "$REGISTRY_PASSWORD" ] && MISSING_PARAMS+=("Registry Password (-p or DOCKER_REGISTRY_SECRET)")
[ -z "$REGISTRY_PREFIX" ]   && MISSING_PARAMS+=("Registry Prefix (-r or DOCKER_REGISTRY_PREFIX)")
[ -z "$SUBDOMAIN" ]         && MISSING_PARAMS+=("Subdomain (-s or SUBDOMAIN_DOCKER_REGISTRY)")
[ -z "$TLD" ]               && MISSING_PARAMS+=("Top-Level Domain (-t or TLD_DOMAIN_URI_ROOT)")

if [ ${#MISSING_PARAMS[@]} -gt 0 ]; then
    echo "❌ Error: Missing required registry configuration."
    echo "Please provide the following missing values:"
    for param in "${MISSING_PARAMS[@]}"; do
        echo "   - $param"
    done
    exit 1
fi

# Configuration is complete, proceed with the script
OCI_FQDN="${SUBDOMAIN}.${TLD}"

# Log into the Docker Registry
echo "🔑 Logging into $OCI_FQDN..."
echo "$REGISTRY_PASSWORD" | docker login -u admin --password-stdin "$OCI_FQDN" || exit 1

# Process each directory passed in the comma-separated list
IFS=',' read -ra DIRS <<< "$IMAGE_DIRECTORIES"
for DIR in "${DIRS[@]}"; do
    
    # Safely resolve absolute path and extract the last child directory name
    ABS_DIR=$(cd "$DIR" && pwd)
    DIR_NAME=$(basename "$ABS_DIR")

    VERSION_FILE="$ABS_DIR/VERSION"
    if [ ! -f "$VERSION_FILE" ]; then
        echo "⚠️ No VERSION file found in $ABS_DIR. Skipping..."
        continue
    fi

    # Read the VERSION file dynamically
    while IFS='=' read -r KEY CURRENT_VERSION || [[ -n "$KEY" ]]; do
        # Skip empty lines and comments
        [[ -z "$KEY" || "$KEY" == \#* ]] && continue

        # Handle both generic 'default' markers and specific app names
        if [[ "$KEY" == "default" || "$KEY" == "$DIR_NAME" ]]; then
            DOCKERFILE_TARGET="$ABS_DIR/Dockerfile"
            IMAGE_REPO="${OCI_FQDN}/${REGISTRY_PREFIX}/${DIR_NAME}"
            DISPLAY_NAME="${DIR_NAME}"
        else
            DOCKERFILE_TARGET="$ABS_DIR/Dockerfile.${KEY}"
            IMAGE_REPO="${OCI_FQDN}/${REGISTRY_PREFIX}/${DIR_NAME}-${KEY}"
            DISPLAY_NAME="${DIR_NAME}-${KEY}"
        fi

        if [ ! -f "$DOCKERFILE_TARGET" ]; then
            echo "⚠️ Dockerfile target $DOCKERFILE_TARGET does not exist. Skipping..."
            continue
        fi

        echo "🚀 Building multi-arch image for ${DISPLAY_NAME} (version: $CURRENT_VERSION)"

        # Isolate the 'v' prefix if it exists
        if [[ "$CURRENT_VERSION" == v* ]]; then
            PREFIX="v"
            CLEAN_VERSION="${CURRENT_VERSION#v}"
        else
            PREFIX=""
            CLEAN_VERSION="$CURRENT_VERSION"
        fi

        # ==========================================================================
        # SEMANTIC VERSIONING PARSER (BNF Compliant)
        # Regex captures: Major(1), Minor(2), Patch(3), Pre-release(4), Build(5)
        # ==========================================================================
        SEMVER_REGEX="^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"
        
        DOCKER_TAGS=()

        if [[ "$CLEAN_VERSION" =~ $SEMVER_REGEX ]]; then
            MAJOR="${BASH_REMATCH[1]}"
            MINOR="${BASH_REMATCH[2]}"
            PATCH="${BASH_REMATCH[3]}"
            PRERELEASE="${BASH_REMATCH[4]}" # Includes leading '-'
            BUILD="${BASH_REMATCH[5]}"      # Includes leading '+'

            # OCI/Docker tags do not support the '+' character. 
            # We sanitize the full version string by substituting '+' with '__'.
            SAFE_BUILD="${BUILD//+/__}"
            FULL_VERSION="${PREFIX}${MAJOR}.${MINOR}.${PATCH}${PRERELEASE}${SAFE_BUILD}"
            
            # 1. Always tag the exact granular version
            DOCKER_TAGS+=("-t" "${IMAGE_REPO}:${FULL_VERSION}")

            # 2. If stable release (no pre-release/build metadata), apply floating tags
            if [ -z "$PRERELEASE" ] && [ -z "$BUILD" ]; then
                DOCKER_TAGS+=(
                    "-t" "${IMAGE_REPO}:latest"
                    "-t" "${IMAGE_REPO}:${PREFIX}${MAJOR}"
                    "-t" "${IMAGE_REPO}:${PREFIX}${MAJOR}.${MINOR}"
                )
            fi

            # 3. Create standalone tags for Pre-release and Build identifiers (like 'latest')
            if [ -n "$PRERELEASE" ]; then
                STANDALONE_PRE="${PRERELEASE#-}" # Strip the leading '-'
                DOCKER_TAGS+=("-t" "${IMAGE_REPO}:${STANDALONE_PRE}")
            fi

            if [ -n "$BUILD" ]; then
                STANDALONE_BUILD="${BUILD#+}"    # Strip the leading '+'
                DOCKER_TAGS+=("-t" "${IMAGE_REPO}:${STANDALONE_BUILD}")
            fi
        else
            # Fallback for non-SemVer strings (e.g., arbitrary branch names)
            SAFE_VERSION="${CURRENT_VERSION//+/__}"
            DOCKER_TAGS+=("-t" "${IMAGE_REPO}:${SAFE_VERSION}")
        fi

        # Build and push the image for both architectures
        docker buildx build \
          --platform linux/amd64,linux/arm64 \
          "${DOCKER_TAGS[@]}" \
          -f "${DOCKERFILE_TARGET}" \
          --push \
          "$ABS_DIR"
          
        echo "✅ Successfully built and pushed ${IMAGE_REPO}"

    done < "$VERSION_FILE"
done