#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build + push Docker image from repo root and keep version history.

Usage:
  bash scripts/release_docker.sh [--image <registry/repo/name>] [--bump patch|minor|major] [--version X.Y.Z]
                                [--platform linux/amd64,linux/arm64] [--py-version 3.12]
                                [--no-latest] [--no-push] [--dry-run]

Examples:
  bash scripts/release_docker.sh
  bash scripts/release_docker.sh --bump minor
  bash scripts/release_docker.sh --version 0.1.0
  bash scripts/release_docker.sh --image ghcr.io/acme/aegra-api
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_semver() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

semver_bump() {
  local v="$1"
  local bump="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$v"

  case "$bump" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *) die "unknown bump: $bump (expected major|minor|patch)" ;;
  esac
}

IMAGE="mikelarg/aegra"
BUMP="patch"
EXPLICIT_VERSION=""
PLATFORM="linux/amd64,linux/arm64"
PY_VERSION="3.12"
PUSH="1"
TAG_LATEST="1"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --bump) BUMP="${2:-}"; shift 2 ;;
    --version) EXPLICIT_VERSION="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --py-version) PY_VERSION="${2:-}"; shift 2 ;;
    --no-push) PUSH="0"; shift ;;
    --no-latest) TAG_LATEST="0"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    *) die "unknown argument: $1 (run with --help)" ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
VERSION_FILE="${REPO_ROOT}/deployments/docker/VERSION"
VERSIONS_LOG="${REPO_ROOT}/deployments/docker/VERSIONS.md"
DOCKERFILE="${REPO_ROOT}/deployments/docker/Dockerfile"

[[ -f "$DOCKERFILE" ]] || die "Dockerfile not found: $DOCKERFILE"
[[ -f "$VERSION_FILE" ]] || die "VERSION file not found: $VERSION_FILE"

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
is_semver "$CURRENT_VERSION" || die "invalid current VERSION: '$CURRENT_VERSION'"

if [[ -n "$EXPLICIT_VERSION" ]]; then
  is_semver "$EXPLICIT_VERSION" || die "invalid --version: '$EXPLICIT_VERSION'"
  NEW_VERSION="$EXPLICIT_VERSION"
else
  NEW_VERSION="$(semver_bump "$CURRENT_VERSION" "$BUMP")"
fi

TAG_VERSION="${IMAGE}:${NEW_VERSION}"
TAG_LATEST_NAME="${IMAGE}:latest"

echo "Repo:           $REPO_ROOT"
echo "Dockerfile:     $DOCKERFILE"
echo "Image:          $IMAGE"
echo "Current:        $CURRENT_VERSION"
echo "New:            $NEW_VERSION"
echo "Tags:           $TAG_VERSION$( [[ "$TAG_LATEST" == "1" ]] && echo ", $TAG_LATEST_NAME" || true )"
echo "Platform:       $PLATFORM"
echo "Python version: $PY_VERSION"
echo "Push:           $PUSH"
echo "Dry run:        $DRY_RUN"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

BUILD_ARGS=(--build-arg "PY_VERSION=${PY_VERSION}")

if docker buildx version >/dev/null 2>&1; then
  BUILD_CMD=(docker buildx build --platform "$PLATFORM" -f "$DOCKERFILE")
  BUILD_CMD+=("${BUILD_ARGS[@]}")
  BUILD_CMD+=(-t "$TAG_VERSION")
  if [[ "$TAG_LATEST" == "1" ]]; then
    BUILD_CMD+=(-t "$TAG_LATEST_NAME")
  fi
  if [[ "$PUSH" == "1" ]]; then
    BUILD_CMD+=(--push)
  else
    if [[ "$PLATFORM" == *","* ]]; then
      die "--no-push requires a single platform (example: --platform linux/amd64)"
    fi
    BUILD_CMD+=(--load)
  fi
  BUILD_CMD+=("$REPO_ROOT")
  "${BUILD_CMD[@]}"
else
  echo "warning: docker buildx not available; building single-arch local image" >&2
  docker build -f "$DOCKERFILE" "${BUILD_ARGS[@]}" -t "$TAG_VERSION" "$REPO_ROOT"
  if [[ "$TAG_LATEST" == "1" ]]; then
    docker tag "$TAG_VERSION" "$TAG_LATEST_NAME"
  fi
  if [[ "$PUSH" == "1" ]]; then
    docker push "$TAG_VERSION"
    if [[ "$TAG_LATEST" == "1" ]]; then
      docker push "$TAG_LATEST_NAME"
    fi
  fi
fi

printf "%s\n" "$NEW_VERSION" > "$VERSION_FILE"

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
NOW_UTC="$(date -u +"%Y-%m-%d %H:%M:%SZ")"

if [[ ! -f "$VERSIONS_LOG" ]]; then
  cat >"$VERSIONS_LOG" <<'EOF'
## Docker image versions

This file is maintained by `scripts/release_docker.sh`.
EOF
fi

echo "" >>"$VERSIONS_LOG"
echo "- ${NEW_VERSION} (${NOW_UTC}, git ${GIT_SHA})" >>"$VERSIONS_LOG"

if [[ "$PUSH" == "1" ]]; then
  echo "done: pushed $TAG_VERSION"
  if [[ "$TAG_LATEST" == "1" ]]; then
    echo "done: pushed $TAG_LATEST_NAME"
  fi
else
  echo "done: built $TAG_VERSION"
  if [[ "$TAG_LATEST" == "1" ]]; then
    echo "done: tagged $TAG_LATEST_NAME"
  fi
fi
