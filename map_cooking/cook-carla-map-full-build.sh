#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-carla-editor:0.9.15-ubuntu20.04}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/carla-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/carla-builds}"
# Overrides. Normally everything below is detected from the map folder.
DEST_REL="${DEST_REL:-}"
GAME_PATH_OVERRIDE="${GAME_PATH_OVERRIDE:-}"
PACKAGE_CONFIG="${PACKAGE_CONFIG:-Shipping}"
ARCHIVE_SUFIX="${ARCHIVE_SUFIX:-}"
SET_DEFAULT_MAP="${SET_DEFAULT_MAP:-false}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-carla-runtime:0.9.15}"
RUNTIME_BASE="${RUNTIME_BASE:-ubuntu:18.04}"
BUILD_RUNTIME_IMAGE="${BUILD_RUNTIME_IMAGE:-true}"

usage() {
  cat <<'USAGE'
Build a custom CARLA 0.9.15 release (a full, runnable CARLA package) with a map
made with the Digital Twin Tool baked in, plus a lightweight runtime container
that runs the package mounted from the host.

This is the alternative to cook-carla-map.sh: instead of a small map package
that you import into a prebuilt CARLA binary (which crashes on Digital Twin
maps, see carla-simulator/carla#8696), the map is cooked into a complete CARLA
build whose binaries come from the same (fixed) Unreal Engine fork, i.e. the
official CARLA release pipeline: `make package`.

Usage:
  cook-carla-map-full-build.sh [options] <map-folder> [map-name]

Arguments:
  map-folder   The map's content folder as saved by the Digital Twin Tool: the
               .umap, its assets (Static/, StreetMap/, ...) and
               OpenDrive/<map-name>.xodr. It is mounted read-only and copied
               into the container.
  map-name     Optional. Name of the .umap (without extension). Only needed if
               the folder contains more than one .umap.

Detected from the folder (as in cook-carla-map.sh):
  - the map name (the .umap file)
  - where the folder belongs inside the project's Content/ folder, read from
    the /Game/... asset paths stored in the .umap

What the script does:
  1. In the carla-editor container: copies the map into Content/<detected
     location>, registers it in DefaultGame.ini (+MapsToCook=...) and stages
     its OpenDrive/ (and Nav/, TM/) folder as UFS so the server can read the
     .xodr at runtime, then runs the full `make package` (this cooks ALL
     maps, including yours, builds the CARLA binaries and produces
     Dist/CARLA_<version>_<sufix>.tar.gz).
  2. On the host: extracts the tarball into <output>/CARLA_<version>_<sufix>/
     (the mountable build) and builds the lightweight runtime image
     (default: carla-runtime:0.9.15, ~350 MB, no CARLA content inside).
  3. Prints the docker run command to start CARLA with the build mounted.

This is a LONG build: it cooks all CARLA maps plus yours and compiles the
CARLA client binaries. Expect several hours and roughly 60-80 GB of free
space on the Docker volume (staging + tarball + extracted build).

Options:
  -o, --output DIR          Host folder for the build, tarball and log
                            (default: <script folder>/carla-builds)
  --image IMAGE             Editor Docker image
                            (default: carla-editor:0.9.15-ubuntu20.04)
  --dest REL_PATH           Content-relative location of the map folder
  --game-path PATH          Full /Game/... asset path of the .umap, e.g.
                            /Game/CustomMaps/MyMap/MyMap
  --config CONF             Package configuration: Shipping (default),
                            Development or Debug
  --archive-sufix S         Suffix for the tarball/build folder name
                            (default: the map name)
  --set-default-map         Make your map the default map loaded at startup
                            (rewrites GameDefaultMap/ServerDefaultMap in
                            DefaultEngine.ini). Without this, start CARLA
                            with -map=<path> (printed at the end).
  --runtime-image TAG       Tag for the lightweight runtime image
                            (default: carla-runtime:0.9.15)
  --runtime-base IMAGE      Base image of the runtime container
                            (default: ubuntu:18.04, same OS as the official
                            CARLA docker image; use e.g. ubuntu:20.04 if you
                            get missing-glibc-symbol errors)
  --no-runtime-image        Skip building the runtime image (tarball +
                            extracted build only)
  -h, --help                Show this help

Environment variables: IMAGE_NAME, OUTPUT_DIR, BUILD_DIR (CARLA's Build/
  folder, default <script folder>/carla-build, created by the build script),
  PACKAGE_CONFIG, ARCHIVE_SUFIX, SET_DEFAULT_MAP, RUNTIME_IMAGE,
  RUNTIME_BASE, BUILD_RUNTIME_IMAGE, DEST_REL, GAME_PATH_OVERRIDE.

Output:
  <output>/CARLA_<version>_<sufix>/       extracted, mountable CARLA build
  <output>/CARLA_<version>_<sufix>.tar.gz the release tarball (safe to delete)
  <output>/<map-name>-fullbuild-<time>.log  full console log
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Print the Content/-relative folder the map folder belongs in. The .umap stores
# the /Game/... package names of everything it references, so we look up the
# name of one of the folder's own assets (or of the .umap itself) and take away
# the part that is relative to the map folder. (Same logic as cook-carla-map.sh)
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
    --game-path)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      GAME_PATH_OVERRIDE="$2"; shift 2 ;;
    --config)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      PACKAGE_CONFIG="$2"; shift 2 ;;
    --archive-sufix)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      ARCHIVE_SUFIX="$2"; shift 2 ;;
    --set-default-map)
      SET_DEFAULT_MAP=true; shift ;;
    --runtime-image)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      RUNTIME_IMAGE="$2"; shift 2 ;;
    --runtime-base)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      RUNTIME_BASE="$2"; shift 2 ;;
    --no-runtime-image)
      BUILD_RUNTIME_IMAGE=false; shift ;;
    --image)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      IMAGE_NAME="$2"; shift 2 ;;
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

[[ "$PACKAGE_CONFIG" == "Shipping" || "$PACKAGE_CONFIG" == "Development" || "$PACKAGE_CONFIG" == "Debug" ]] \
  || die "PACKAGE_CONFIG must be Shipping, Development or Debug"
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

MAP_GAME_PATH="${GAME_PATH_OVERRIDE:-/Game/$DEST_REL${UMAP_SUBDIR:+/$UMAP_SUBDIR}/$MAP_NAME}"
[[ "$MAP_GAME_PATH" == /Game/* ]] || die "Invalid game path: '$MAP_GAME_PATH' (must start with /Game/)"
ARCHIVE_SUFIX="${ARCHIVE_SUFIX:-$MAP_NAME}"
[[ "$ARCHIVE_SUFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "archive sufix '$ARCHIVE_SUFIX' must contain only letters, digits and underscores"
[[ "$SET_DEFAULT_MAP" == "true" || "$SET_DEFAULT_MAP" == "false" ]] || die "SET_DEFAULT_MAP must be true or false"
[[ "$BUILD_RUNTIME_IMAGE" == "true" || "$BUILD_RUNTIME_IMAGE" == "false" ]] || die "BUILD_RUNTIME_IMAGE must be true or false"

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

TMP_DIR="$(mktemp -d -t carla-fullbuild.XXXXXXXX)"
CONTAINER_NAME="carla-fullbuild-$$"
cleanup() {
  rm -rf "$TMP_DIR"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Script that runs inside the container. Quoted heredoc: nothing is expanded
# here; values arrive as environment variables from `docker run -e`.
cat > "$TMP_DIR/cook.sh" <<'EOF_COOK'
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

CARLA=/home/carla/carla
CONTENT="$CARLA/Unreal/CarlaUE4/Content"
CONFIG="$CARLA/Unreal/CarlaUE4/Config"
GAME_INI="$CONFIG/DefaultGame.ini"
ENGINE_INI="$CONFIG/DefaultEngine.ini"
DEST="$CONTENT/$DEST_REL"

# Append one line to a file directly after the last line starting with PREFIX.
# Does nothing (success) if LINE is already present in the file.
append_after_last() {
  local file="$1" prefix="$2" line="$3"
  grep -qF -- "$line" "$file" && return 0
  awk -v prefix="$prefix" -v line="$line" '
    { lines[NR] = $0; if (index($0, prefix) == 1) last = NR }
    END {
      if (last == 0) {
        print "ERROR: no line starting with \x27" prefix "\x27 found in " FILENAME > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= NR; i++) { print lines[i]; if (i == last) print line }
    }' "$file" > "$file.new" || { rm -f "$file.new"; return 1; }
  mv "$file.new" "$file"
}

echo "==> Copying map folder into the project"
echo "    from: /input/map"
echo "    to  : $DEST"
mkdir -p "$DEST"
cp -rT --no-preserve=ownership /input/map "$DEST"
chmod -R u+rwX "$DEST"

echo "==> Checking map files"
[[ -f "$DEST/$UMAP_REL" ]] || die "$DEST/$UMAP_REL missing after copy"
XODR="$(find "$DEST" -type f -name "${MAP_NAME}.xodr" | head -n1)"
[[ -n "$XODR" ]] || die "${MAP_NAME}.xodr not found under $DEST (the OpenDRIVE file must have the same name as the map)"
[[ -d "$DEST/OpenDrive" ]] || die "no OpenDrive/ folder under $DEST (needed to stage the .xodr for the server)"
echo "    map  : $DEST/$UMAP_REL"
echo "    xodr : $XODR"
echo "    Unreal path: $MAP_GAME_PATH"

echo "==> Registering the map in $GAME_INI"
append_after_last "$GAME_INI" '+MapsToCook=' "+MapsToCook=(FilePath=\"${MAP_GAME_PATH}\")"
grep -qF "+MapsToCook=(FilePath=\"${MAP_GAME_PATH}\")" "$GAME_INI" \
  || die "failed to add the map to MapsToCook"
echo "    +MapsToCook=(FilePath=\"${MAP_GAME_PATH}\")"
for sub in OpenDrive Nav TM; do
  if [[ -d "$DEST/$sub" ]]; then
    append_after_last "$GAME_INI" '+DirectoriesToAlwaysStageAsUFS=' "+DirectoriesToAlwaysStageAsUFS=(Path=\"${DEST_REL}/${sub}\")"
    grep -qF "+DirectoriesToAlwaysStageAsUFS=(Path=\"${DEST_REL}/${sub}\")" "$GAME_INI" \
      || die "failed to stage ${DEST_REL}/${sub} as UFS"
    echo "    +DirectoriesToAlwaysStageAsUFS=(Path=\"${DEST_REL}/${sub}\")"
  fi
done

if [[ "$SET_DEFAULT_MAP" == "true" ]]; then
  echo "==> Setting the default map in $ENGINE_INI"
  sed -i "s|^GameDefaultMap=.*|GameDefaultMap=${MAP_GAME_PATH}.${MAP_NAME}|" "$ENGINE_INI"
  sed -i "s|^ServerDefaultMap=.*|ServerDefaultMap=${MAP_GAME_PATH}.${MAP_NAME}|" "$ENGINE_INI"
  grep -qF "GameDefaultMap=${MAP_GAME_PATH}.${MAP_NAME}" "$ENGINE_INI" \
    || die "failed to set GameDefaultMap"
  echo "    GameDefaultMap=${MAP_GAME_PATH}.${MAP_NAME}"
fi

echo "==> Cooking and packaging the full CARLA release: make package ARGS=\"--config=${PACKAGE_CONFIG} --archive-sufix=${ARCHIVE_SUFIX}\""
echo "    (this cooks ALL maps including yours, builds the CARLA binaries and can take several hours)"
cd "$CARLA"
make package ARGS="--config=${PACKAGE_CONFIG} --archive-sufix=${ARCHIVE_SUFIX}"

echo "==> Collecting results"
shopt -s nullglob
PKGS=("$CARLA"/Dist/"CARLA"_*"_${ARCHIVE_SUFIX}".tar.gz)
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "ERROR: no CARLA_*_${ARCHIVE_SUFIX}.tar.gz found in $CARLA/Dist" >&2
  ls -la "$CARLA/Dist" >&2 || true
  exit 1
fi
PKG="${PKGS[0]}"
echo "    release: ${PKG##*/}"
# The server reads the OpenDRIVE file from the mounted package; it must be
# there as a loose file.
tar -tzf "$PKG" | grep -F "/${MAP_NAME}.xodr" >/dev/null \
  || die "${MAP_NAME}.xodr is missing from the package - the map would not be usable"
cp -f "$PKG" /output/
chmod a+r /output/"${PKG##*/}" || true
echo "    copied to /output: ${PKG##*/}"
echo "==> Done (container phase)"
EOF_COOK

# Keep Ctrl-C working when run from a terminal; always allocate a pseudo-TTY so
# the tools in the container print their output unbuffered, i.e. live.
TTY_ARGS=(-t)
if [[ -t 0 ]]; then
  TTY_ARGS=(-i -t)
fi

LOG_FILE="$OUTPUT_DIR/${MAP_NAME}-fullbuild-$(date +%Y%m%d-%H%M%S).log"

echo "Image         : $IMAGE_NAME"
echo "Map folder    : $MAP_DIR"
echo "Map name      : $MAP_NAME   ($UMAP_REL)"
echo "Copied to     : Content/$DEST_REL   ($DEST_SOURCE)"
echo "Unreal path   : $MAP_GAME_PATH"
echo "Default map   : $([[ "$SET_DEFAULT_MAP" == "true" ]] && echo yes || echo "no (start with -map=...)")"
echo "Package config: $PACKAGE_CONFIG"
echo "Archive sufix : $ARCHIVE_SUFIX"
echo "Build dir     : $BUILD_DIR"
echo "Output dir    : $OUTPUT_DIR"
echo "Runtime image : $([[ "$BUILD_RUNTIME_IMAGE" == "true" ]] && echo "$RUNTIME_IMAGE (base: $RUNTIME_BASE)" || echo "skipped (--no-runtime-image)")"
echo "Log file      : $LOG_FILE"
echo
echo "This is a full CARLA release build: expect several hours."
echo

set +e
docker run --rm "${TTY_ARGS[@]}" \
  --name "$CONTAINER_NAME" \
  --entrypoint /bin/bash \
  -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
  -e "MAP_NAME=$MAP_NAME" \
  -e "UMAP_REL=$UMAP_REL" \
  -e "DEST_REL=$DEST_REL" \
  -e "MAP_GAME_PATH=$MAP_GAME_PATH" \
  -e "PACKAGE_CONFIG=$PACKAGE_CONFIG" \
  -e "ARCHIVE_SUFIX=$ARCHIVE_SUFIX" \
  -e "SET_DEFAULT_MAP=$SET_DEFAULT_MAP" \
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
  if grep -qE 'DistanceFieldVolumeTexture|DistanceFieldAtlas' "$LOG_FILE" 2>/dev/null; then
    echo "The log contains the distance-field crash signature from carla-simulator/carla#8696."
    echo "This means the Unreal Engine fork inside $IMAGE_NAME predates the fix"
    echo "(commit a288ae07 on the CarlaUnreal/UnrealEngine 'carla' branch)."
    echo "Rebuild the editor image from the current 'carla' branch and retry."
    echo
  fi
  echo "FAILED (exit code $STATUS). Full log: $LOG_FILE" >&2
  exit "$STATUS"
fi

shopt -s nullglob
TARBALLS=("$OUTPUT_DIR"/CARLA_*"_${ARCHIVE_SUFIX}".tar.gz)
[[ ${#TARBALLS[@]} -gt 0 ]] || die "Container finished but no tarball found in $OUTPUT_DIR"
# Newest first, in case an earlier run left a tarball with the same name.
TARBALL="$(ls -1t "${TARBALLS[@]}" | head -n1)"
VERSION="$(basename "$TARBALL" "_${ARCHIVE_SUFIX}.tar.gz")"
BUILD_FOLDER="$OUTPUT_DIR/${VERSION}_${ARCHIVE_SUFIX}"

echo "==> Extracting the build to $BUILD_FOLDER"
if [[ -e "$BUILD_FOLDER" ]]; then
  echo "    removing existing $BUILD_FOLDER"
  rm -rf "$BUILD_FOLDER"
fi
mkdir -p "$BUILD_FOLDER"
tar -xzf "$TARBALL" -C "$BUILD_FOLDER"
[[ -f "$BUILD_FOLDER/CarlaUE4.sh" ]] || die "CarlaUE4.sh not found in the extracted build - is this a valid CARLA package?"
XODR_IN_BUILD="$(find "$BUILD_FOLDER/CarlaUE4/Content" -type f -name "${MAP_NAME}.xodr" -print -quit 2>/dev/null || true)"
if [[ -n "$XODR_IN_BUILD" ]]; then
  echo "    xodr in build: ${XODR_IN_BUILD#"$BUILD_FOLDER"/}"
else
  echo "    WARNING: ${MAP_NAME}.xodr not found in the extracted build" >&2
fi

# Dockerfile for the lightweight runtime container (no CARLA content baked in;
# the build is mounted as a volume at runtime).
cat > "$TMP_DIR/runtime.Dockerfile" <<EOF_RUNTIME
# Lightweight runtime container for a CARLA package that lives on the host and
# is mounted as a volume at runtime. No CARLA content is baked in.
FROM ${RUNTIME_BASE}

RUN apt-get update && \\
    apt-get install -y --no-install-recommends \\
      libsdl2-2.0 \\
      libvulkan1 \\
      libomp5 && \\
    rm -rf /var/lib/apt/lists/*

WORKDIR /carla
CMD ["./CarlaUE4.sh"]
EOF_RUNTIME

RUNTIME_OK=false
if [[ "$BUILD_RUNTIME_IMAGE" == "true" ]]; then
  echo "==> Building the lightweight runtime image $RUNTIME_IMAGE (base: $RUNTIME_BASE)"
  set +e
  docker build -q -t "$RUNTIME_IMAGE" -f "$TMP_DIR/runtime.Dockerfile" "$TMP_DIR" 2>&1 | tee -a "$LOG_FILE"
  RUNTIME_STATUS="${PIPESTATUS[0]}"
  set -e
  if [[ "$RUNTIME_STATUS" -eq 0 ]]; then
    RUNTIME_OK=true
    echo "    runtime image ready: $RUNTIME_IMAGE"
  else
    echo "WARNING: building the runtime image failed (exit $RUNTIME_STATUS)." >&2
    echo "         The CARLA build itself is fine; build the image manually later:" >&2
    echo "           docker build -t $RUNTIME_IMAGE -f <Dockerfile> ." >&2
    echo "         (the Dockerfile is printed at the end of this message)" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------------
echo
echo "Success."
echo "  CARLA build (on host) : $BUILD_FOLDER"
echo "  Release tarball       : $TARBALL   (safe to delete)"
[[ "$RUNTIME_OK" == "true" ]] && echo "  Runtime image           : $RUNTIME_IMAGE"
echo "  Log                   : $LOG_FILE"
echo
echo "Run the custom CARLA with the build mounted from the host:"
echo
if [[ "$SET_DEFAULT_MAP" == "true" ]]; then
  echo "  docker run --rm -it --gpus all --net=host \\"
  echo "    -v \"${BUILD_FOLDER}:/carla\" \\"
  echo "    ${RUNTIME_IMAGE} ./CarlaUE4.sh"
else
  echo "  docker run --rm -it --gpus all --net=host \\"
  echo "    -v \"${BUILD_FOLDER}:/carla\" \\"
  echo "    ${RUNTIME_IMAGE} ./CarlaUE4.sh -map=${MAP_GAME_PATH}"
fi
echo
echo "Your map's Unreal path: ${MAP_GAME_PATH}"
echo
echo "Notes:"
echo "  - --gpus all passes the host GPU into the container (Vulkan)."
echo "  - Add -RenderOffScreen for headless/offscreen rendering."
echo "  - If CARLA fails with missing glibc symbols, rebuild the runtime image"
echo "    with a newer base: --runtime-base ubuntu:20.04"
echo "  - If you get permission errors inside the mounted build, run the"
echo "    container with -u \"\$(id -u):\$(id -g)\"."
if [[ "$BUILD_RUNTIME_IMAGE" != "true" || "$RUNTIME_OK" != "true" ]]; then
  echo
  echo "Dockerfile for the runtime image (build it with: docker build -t TAG -f Dockerfile .):"
  echo "----------------------------------------------------------------------"
  sed 's/^/    /' "$TMP_DIR/runtime.Dockerfile" 2>/dev/null || true
  echo "----------------------------------------------------------------------"
fi
