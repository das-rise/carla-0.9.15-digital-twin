#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-carla-editor:0.9.15-ubuntu20.04}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/carla-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/cooked-maps}"
USE_CARLA_MATERIALS="${USE_CARLA_MATERIALS:-true}"
# Overrides. Normally everything below is detected from the map folder.
DEST_REL="${DEST_REL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
PACKAGE_ROOT="${PACKAGE_ROOT:-}"
GAME_PATH_OVERRIDE="${GAME_PATH_OVERRIDE:-}"

usage() {
  cat <<'USAGE'
Cook and package a CARLA map (e.g. made with the Digital Twin Tool) inside the
carla-editor container.

Usage:
  cook-carla-map.sh [options] <map-folder> [map-name]

Arguments:
  map-folder   The map's content folder as saved by the Digital Twin Tool: the
               .umap, its assets (Static/, StreetMap/, ...) and
               OpenDrive/<map-name>.xodr. It must contain everything the map
               needs. It is mounted read-only and copied into the container.
  map-name     Optional. Name of the .umap (without extension). Only needed if
               the folder contains more than one .umap.

Detected from the folder:
  - the map name (the .umap file)
  - where the folder belongs inside the project's Content/ folder, read from the
    /Game/... asset paths stored in the .umap (e.g. /Game/CustomMaps/MyMap/...
    means Content/CustomMaps/MyMap)
  - the package root (first folder of that location) and the Package.json "path"

Options (overrides, normally not needed):
  -o, --output DIR        Host folder for the package and the log
                          (default: <script folder>/cooked-maps)
  --dest REL_PATH         Content-relative location of the map folder
  --package NAME          Package name (default: map name)
  --package-root NAME     Content/<NAME>/Config gets the Package.json
  --game-path PATH        "path" written to the Package.json
  --no-carla-materials    Write "use_carla_materials": false
  --image IMAGE           Docker image (default: carla-editor:0.9.15-ubuntu20.04)
  -h, --help              Show this help

Environment variables: IMAGE_NAME, OUTPUT_DIR, USE_CARLA_MATERIALS, DEST_REL,
  PACKAGE_NAME, PACKAGE_ROOT, GAME_PATH_OVERRIDE, and BUILD_DIR (CARLA's Build/
  folder, default <script folder>/carla-build, created by the build script).

Output:
  <output>/<package>*.tar.gz            the cooked package
  <output>/<package>.Package.json       the config that was used
  <output>/<map-name>-cook-<time>.log   full console log

All container output is shown live and also saved to the log. The container is
removed when it exits (--rm); the package survives in <output>.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Print the Content/-relative folder the map folder belongs in. The .umap stores
# the /Game/... package names of everything it references, so we look up the
# name of one of the folder's own assets (or of the .umap itself) and take away
# the part that is relative to the map folder.
detect_dest() {
  local dir="$1" umap="$2" list f rel line
  list="$(grep -aoE '/Game/[A-Za-z0-9_/.-]+' "$umap" | sort -u)" || true
  [[ -n "$list" ]] || return 1
  while IFS= read -r f; do
    rel="${f#"$dir"/}"
    rel="${rel%.*}"
    while IFS= read -r line; do
      if [[ "$line" == *"/$rel" ]]; then
        line="${line%"/$rel"}"
        echo "${line#/Game/}"
        return 0
      fi
    done < <(grep -F -- "/$rel" <<<"$list" || true)
  done < <({ find "$dir" -type f -name '*.uasset' | head -n 50; printf '%s\n' "$umap"; })
  return 1
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      OUTPUT_DIR="$2"; shift 2 ;;
    --dest)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      DEST_REL="$2"; shift 2 ;;
    --package)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      PACKAGE_NAME="$2"; shift 2 ;;
    --package-root)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      PACKAGE_ROOT="$2"; shift 2 ;;
    --game-path)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      GAME_PATH_OVERRIDE="$2"; shift 2 ;;
    --image)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      IMAGE_NAME="$2"; shift 2 ;;
    --no-carla-materials)
      USE_CARLA_MATERIALS=false; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      usage >&2; die "Unknown option: $1" ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

[[ ${#POSITIONAL[@]} -ge 1 && ${#POSITIONAL[@]} -le 2 ]] || { usage >&2; die "Expected <map-folder> and optionally [map-name]"; }
MAP_DIR="${POSITIONAL[0]}"
MAP_NAME="${POSITIONAL[1]:-}"

[[ "$USE_CARLA_MATERIALS" == "true" || "$USE_CARLA_MATERIALS" == "false" ]] || die "USE_CARLA_MATERIALS must be true or false"
[[ -d "$MAP_DIR" ]] || die "Map folder not found: $MAP_DIR"
MAP_DIR="$(cd "$MAP_DIR" && pwd)"

# --- Find the .umap and the map name ------------------------------------------
mapfile -t UMAPS < <(find "$MAP_DIR" -type f -name '*.umap' | sort)
UMAP_FILE=""
if [[ -n "$MAP_NAME" ]]; then
  for u in ${UMAPS[@]+"${UMAPS[@]}"}; do
    if [[ "$(basename "$u" .umap)" == "$MAP_NAME" ]]; then UMAP_FILE="$u"; break; fi
  done
  [[ -n "$UMAP_FILE" ]] || die "No ${MAP_NAME}.umap found in $MAP_DIR"
else
  [[ ${#UMAPS[@]} -gt 0 ]] || die "No .umap file found in $MAP_DIR"
  if [[ ${#UMAPS[@]} -gt 1 ]]; then
    printf '  %s\n' "${UMAPS[@]}" >&2
    die "More than one .umap found in $MAP_DIR; pass the map name as second argument"
  fi
  UMAP_FILE="${UMAPS[0]}"
  MAP_NAME="$(basename "$UMAP_FILE" .umap)"
fi
[[ "$MAP_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "map name '$MAP_NAME' must contain only letters, digits and underscores"
UMAP_REL="${UMAP_FILE#"$MAP_DIR"/}"
UMAP_SUBDIR="$(dirname "$UMAP_REL")"
[[ "$UMAP_SUBDIR" != "." ]] || UMAP_SUBDIR=""

# --- Where does the folder belong inside Content/? ----------------------------
if [[ -n "$DEST_REL" ]]; then
  DEST_SOURCE="given with --dest"
else
  DEST_REL="$(detect_dest "$MAP_DIR" "$UMAP_FILE")" \
    || die "Could not work out where this folder belongs in Content/ (no /Game/... paths of its own files found in ${UMAP_REL}). Pass --dest, e.g. --dest CustomMaps/$(basename "$MAP_DIR")"
  DEST_SOURCE="detected from ${UMAP_REL}"
fi
[[ -n "$DEST_REL" && "$DEST_REL" != /* && "$DEST_REL" != *..* ]] || die "Invalid destination: '$DEST_REL'"

PACKAGE_NAME="${PACKAGE_NAME:-$MAP_NAME}"
[[ "$PACKAGE_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "package name must contain only letters, digits and underscores"
PACKAGE_ROOT="${PACKAGE_ROOT:-${DEST_REL%%/*}}"
GAME_PATH="${GAME_PATH_OVERRIDE:-/Game/$DEST_REL${UMAP_SUBDIR:+/$UMAP_SUBDIR}}"

# --- Environment checks ---------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable."
docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
  || die "Docker image not found: $IMAGE_NAME (run the build script first)"
[[ -d "$BUILD_DIR" ]] || die "Build folder not found: $BUILD_DIR (run the build script first, or set BUILD_DIR)"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
# The container user (uid 1000) must be able to write here.
chmod 777 "$OUTPUT_DIR" 2>/dev/null || true

TMP_DIR="$(mktemp -d -t carla-cook.XXXXXXXX)"
CONTAINER_NAME="carla-cook-$$"
cleanup() {
  rm -rf "$TMP_DIR"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Script that runs inside the container. Quoted heredoc: nothing is expanded
# here; values arrive as environment variables from `docker run -e`.
cat > "$TMP_DIR/cook.sh" <<'EOF_COOK'
set -Eeuo pipefail

CARLA=/home/carla/carla
CONTENT="$CARLA/Unreal/CarlaUE4/Content"
DEST="$CONTENT/$DEST_REL"
CONFIG_DIR="$CONTENT/$PACKAGE_ROOT/Config"

echo "==> Copying map folder into the project"
echo "    from: /input/map"
echo "    to  : $DEST"
mkdir -p "$DEST"
cp -rT --no-preserve=ownership /input/map "$DEST"
chmod -R u+rwX "$DEST"

echo "==> Checking map files"
[[ -f "$DEST/$UMAP_REL" ]] || { echo "ERROR: $DEST/$UMAP_REL missing after copy" >&2; exit 1; }
XODR="$(find "$DEST" -type f -name "${MAP_NAME}.xodr" | head -n1)"
if [[ -z "$XODR" ]]; then
  echo "ERROR: ${MAP_NAME}.xodr not found under $DEST" >&2
  echo "       The OpenDRIVE file must have the same name as the map." >&2
  exit 1
fi
echo "    map  : $DEST/$UMAP_REL"
echo "    xodr : $XODR"
echo "    Unreal path: $GAME_PATH"

echo "==> Writing ${PACKAGE_NAME}.Package.json to Content/${PACKAGE_ROOT}/Config"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/${PACKAGE_NAME}.Package.json" <<EOF_JSON
{
  "maps": [
    {
      "name": "${MAP_NAME}",
      "path": "${GAME_PATH}",
      "use_carla_materials": ${USE_CARLA_MATERIALS}
    }
  ],
  "props": []
}
EOF_JSON
cat "$CONFIG_DIR/${PACKAGE_NAME}.Package.json"

echo "==> Cooking and packaging: make package ARGS=\"--packages=${PACKAGE_NAME}\""
cd "$CARLA"
make package ARGS="--packages=${PACKAGE_NAME}"

echo "==> Collecting results"
shopt -s nullglob
PKGS=("$CARLA"/Dist/"${PACKAGE_NAME}"*.tar.gz)
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "ERROR: no ${PACKAGE_NAME}*.tar.gz found in $CARLA/Dist" >&2
  ls -la "$CARLA/Dist" >&2 || true
  exit 1
fi
cp -f "${PKGS[@]}" /output/
cp -f "$CONFIG_DIR/${PACKAGE_NAME}.Package.json" /output/
chmod a+r /output/"${PACKAGE_NAME}"* || true
printf '    copied to /output: %s\n' "${PKGS[@]##*/}"
echo "==> Done"
EOF_COOK

# Keep Ctrl-C working when run from a terminal; always allocate a pseudo-TTY so
# the tools in the container print their output unbuffered, i.e. live.
TTY_ARGS=(-t)
if [[ -t 0 ]]; then
  TTY_ARGS=(-i -t)
fi

LOG_FILE="$OUTPUT_DIR/${MAP_NAME}-cook-$(date +%Y%m%d-%H%M%S).log"

echo "Image         : $IMAGE_NAME"
echo "Map folder    : $MAP_DIR"
echo "Map name      : $MAP_NAME   ($UMAP_REL)"
echo "Copied to     : Content/$DEST_REL   ($DEST_SOURCE)"
echo "Package       : $PACKAGE_NAME  (root: Content/$PACKAGE_ROOT)"
echo "Package path  : $GAME_PATH"
echo "Build dir     : $BUILD_DIR"
echo "Output dir    : $OUTPUT_DIR"
echo "Log file      : $LOG_FILE"
echo

set +e
docker run --rm "${TTY_ARGS[@]}" \
  --name "$CONTAINER_NAME" \
  --entrypoint /bin/bash \
  -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
  -e "MAP_NAME=$MAP_NAME" \
  -e "UMAP_REL=$UMAP_REL" \
  -e "PACKAGE_NAME=$PACKAGE_NAME" \
  -e "PACKAGE_ROOT=$PACKAGE_ROOT" \
  -e "DEST_REL=$DEST_REL" \
  -e "GAME_PATH=$GAME_PATH" \
  -e "USE_CARLA_MATERIALS=$USE_CARLA_MATERIALS" \
  -v "$BUILD_DIR:/home/carla/carla/Build" \
  -v "$MAP_DIR:/input/map:ro" \
  -v "$OUTPUT_DIR:/output" \
  -v "$TMP_DIR/cook.sh:/cook.sh:ro" \
  "$IMAGE_NAME" /cook.sh 2>&1 | tee "$LOG_FILE"
STATUS="${PIPESTATUS[0]}"
set -e

# The pseudo-TTY adds carriage returns; remove them from the saved log.
sed -i 's/\r$//' "$LOG_FILE" 2>/dev/null || true

echo
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAILED (exit code $STATUS). Full log: $LOG_FILE" >&2
  exit "$STATUS"
fi

shopt -s nullglob
RESULTS=("$OUTPUT_DIR/${PACKAGE_NAME}"*.tar.gz)
[[ ${#RESULTS[@]} -gt 0 ]] || die "Container finished but no package found in $OUTPUT_DIR"

echo "Success. Package(s):"
printf '  %s\n' "${RESULTS[@]}"
echo "Log: $LOG_FILE"
echo
echo "Import into a prebuilt Linux CARLA: copy the .tar.gz into its Import/ folder"
echo "and run ImportAssets.sh."
