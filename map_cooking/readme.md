# Cooking Digital Twin maps for CARLA 0.9.15

This folder turns a map created with the CARLA Digital Twin Tool into a cooked
package that can be imported into a CARLA installation and used for
simulations. A map folder as saved by the tool contains the `.umap`, its
assets (`Static/`, `StreetMap/`, ...) and `OpenDrive/<map-name>.xodr`.

The workflow is two steps:

1. **Build the cooking image once** — `build-carla-0.9.15-editor-ubuntu20.04-cached.sh`
2. **Cook each map** — `cook-carla-map.sh <map-folder>`

## Requirements

| Item                                          | Notes                                                        |
| --------------------------------------------- | ------------------------------------------------------------ |
| Docker with BuildKit/Buildx                   | `docker buildx version` must work                            |
| GitHub account in the Epic Games organisation | The Unreal Engine source (`CarlaUnreal/UnrealEngine`) is private. **Your account must be a member of the Epic Games GitHub organisation**, plus a token with read access |
| Disk space                                    | Well over 100 GB (image, `carla-build/` dependencies, cook output) |
| Time and RAM                                  | The image build takes hours; plenty of RAM and CPU cores help a lot |
| Network                                       | GitHub, the Backblaze CARLA content mirror, SourceForge, boost archive |

## Step 1: Build the cooking image

`build-carla-0.9.15-editor-ubuntu20.04-cached.sh` builds a Docker image
(default tag `carla-editor:0.9.15-ubuntu20.04`) containing the CARLA-patched
Unreal Engine 4.26 (branch `carla`), the CARLA 0.9.15 source with Content, and
the built editor plugins.

```bash
export EPIC_USER="your-github-username"
export EPIC_PASS="your-github-token"
bash build-carla-0.9.15-editor-ubuntu20.04-cached.sh
```

Options:

| Option | Meaning |
|--------|---------|
| `--no-cache` | Disable the layer cache for the base image. Not recommended: it reruns the multi-hour engine build |
| `--help` | Print usage |

Environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `EPIC_USER` | (required) | a GitHub username for a user that is member of the Epc Games GitHub organization |
| `EPIC_PASS` | (required) | a corresponding GitHub token with read access |
| `IMAGE_NAME` | `carla-editor:0.9.15-ubuntu20.04` | Tag of the final image |
| `CARLA_BRANCH` | `0.9.15` | CARLA git branch or tag |
| `UNREAL_BRANCH` | `carla` | Unreal Engine branch |
| `BUILD_DIR` | `<script folder>/carla-build` | Host folder used as CARLA's `Build/` directory |

The build has two phases: a layer-cached `docker buildx build` (engine, CARLA
source, Content download) and `make setup` + `make CarlaUE4Editor` in a
container that is committed as the final image. Credentials are passed as a
BuildKit secret and never end up in an image layer.

**Note:** `Build/` (third-party dependencies) is not part of the image. It
stays on the host in `BUILD_DIR` and must be mounted when you run the image.
Do not delete it unless you want to rebuild the dependencies.

## Step 2: Cook a map

```bash
bash cook-carla-map.sh [options] <map-folder> [map-name]
```

The script copies the map folder into the project, works out the map name (the
`.umap`) and its location inside `Content/` from the `/Game/...` paths stored
in the `.umap`, writes a `Package.json`, and runs
`make package ARGS="--packages=<package>"` inside the editor image.

Options (all optional; everything is detected from the folder unless
overridden):

| Option | Meaning |
|--------|---------|
| `-o, --output DIR` | Host folder for the package and the log (default: `<script folder>/cooked-maps`) |
| `--dest REL_PATH` | Content-relative location of the map folder |
| `--package NAME` | Package name (default: map name) |
| `--package-root NAME` | `Content/<NAME>/Config` gets the `Package.json` (default: first folder of the destination) |
| `--game-path PATH` | The `path` written to the `Package.json` |
| `--no-carla-materials` | Write `"use_carla_materials": false` (default: `true`) |
| `--image IMAGE` | Editor Docker image (default: `carla-editor:0.9.15-ubuntu20.04`) |
| `-h, --help` | Print usage |

Environment variables: `IMAGE_NAME`, `OUTPUT_DIR`, `USE_CARLA_MATERIALS`,
`DEST_REL`, `PACKAGE_NAME`, `PACKAGE_ROOT`, `GAME_PATH_OVERRIDE`, `BUILD_DIR`.

Output (in the output folder):

- `<package>*.tar.gz` — the cooked package
- `<package>.Package.json` — the config that was used
- `<map-name>-cook-<time>.log` — full console log

## Importing the cooked map package

Copy the `.tar.gz` into the `Import/` folder of your CARLA installation and
run `ImportAssets.sh`; it extracts the package over the CARLA root. Then start
CARLA with your map (the `/Game/...` path is printed by the cook script and
written to the `Package.json`):

```bash
./CarlaUE4.sh -map=/Game/<path>/<map-name>
```


> [!IMPORTANT]
>
> For the map to work in CARLA, you need a CARLA build with the correct revision and the patches from this repository applied. One easy way to obtain a compatible CARLA build is to use the one from https://github.com/das-rise/rise-carla-runner#running-digital-twin-tool-maps.
