# CARLA 0.9.15 Editor Image (Ubuntu 20.04)

`build-carla-0.9.15-editor-ubuntu20.04-cached.sh` builds a Docker image containing:

- the CARLA-patched **Unreal Engine 4.26** (`CarlaUnreal/UnrealEngine`, branch `carla`)
- **CARLA 0.9.15** source, downloaded Content, and the built **CarlaUE4 Editor** plugins

The image is intended for opening the project in the Unreal Editor and **cooking maps**, for example maps produced with the CARLA Digital Twin Tool.

## Requirements

| Item | Notes |
|------|-------|
| Docker with BuildKit/Buildx | `docker buildx version` must work |
| GitHub account in the Epic Games organisation | The Unreal Engine source is a private repository (`CarlaUnreal/UnrealEngine`). Your GitHub account must be a member of the **Epic Games GitHub organisation** to pull it, otherwise the clone fails. Membership requires an Epic Games account linked to your GitHub account. See Epic's instructions for accessing the Unreal Engine source on GitHub, and accept the organisation invitation you receive |
| GitHub token | A personal access token with read access to the repository |
| Disk space | Very large. Unreal Engine plus the CARLA content and build products need well over 100 GB. Plan for more |
| Time and RAM | The Unreal Engine build takes hours. Plenty of RAM and CPU cores help a lot |
| Network | The Content archive and several dependencies are downloaded |

## Usage

```bash
export EPIC_USER="your-github-username"
export EPIC_PASS="your-github-token"
bash build-carla-0.9.15-editor-ubuntu20.04-cached.sh
```

Options:

- `--no-cache` disables the Docker layer cache for the base image. Not recommended for normal retries, because it forces the multi-hour Unreal Engine build to run again.
- `--help` prints usage.

Environment variables (all optional):

| Variable | Default | Meaning |
|----------|---------|---------|
| `IMAGE_NAME` | `carla-editor:0.9.15-ubuntu20.04` | Tag of the final image |
| `CARLA_BRANCH` | `0.9.15` | CARLA git branch or tag |
| `UNREAL_BRANCH` | `carla` | CARLA Unreal Engine branch |
| `BUILD_DIR` | `<script folder>/carla-build` | Host folder used as CARLA's `Build/` directory |

Your GitHub credentials are passed to the build as a BuildKit secret. They are not stored in an image layer, and the temporary credential file is deleted when the script exits.

## How it works

The build has two phases.

**Phase 1: base image** (`docker buildx build`, fully layer-cached)

1. Ubuntu 20.04 and the CARLA toolchain (clang-10, cmake, and so on)
2. Unreal Engine 4.26: clone, `Setup.sh`, `GenerateProjectFiles.sh`, `make`. This is the expensive layer
3. CARLA source clone
4. Patch of `Update.sh` (dead download URL replaced, plus an archive cache) and download of the Content
5. Patches to CARLA's build scripts (replacement download URLs and a few fixes). Each patch is verified with `grep`, so the build fails immediately if a patch did not apply
6. `automake`, which CARLA's `Setup.sh` needs for building patchelf

The result is tagged `<IMAGE_NAME>-base`.

**Phase 2: CARLA build** (`docker run` + `docker commit`)

A container from the base image runs `make setup` and `make CarlaUE4Editor` with the host folder `carla-build/` mounted as `/home/carla/carla/Build`. The container is then committed as the final image.

Why two phases: Docker cannot bind-mount a host folder during `docker build`. Running the CARLA build in `docker run` lets the third-party dependencies persist on the host, so a failed or interrupted run resumes instead of rebuilding everything.

## Important: the final image does not contain `Build/`

The bind-mounted `Build/` folder is not committed into the image. It stays on the host in `carla-build/`. **Always mount it when you run the image**:

```bash
docker run --rm -it \
  -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
  -v "$PWD/carla-build:/home/carla/carla/Build" \
  carla-editor:0.9.15-ubuntu20.04
```

`GIT_DISCOVERY_ACROSS_FILESYSTEM=1` is required because CARLA's scripts call `git` from inside `Build/`. Without it, git stops at the mount boundary and fails with `not a git repository`.

Do not delete `carla-build/` unless you want to rebuild the third-party dependencies.

## Caches and files

| Location | Contents |
|----------|----------|
| `./carla-build/` (host) | CARLA third-party dependencies (boost, proj, patchelf, and others) |
| BuildKit cache `carla-content-0.9.15` | The downloaded CARLA Content archive |
| Docker layer cache | Unreal Engine build and the other Phase 1 layers |
| `<IMAGE_NAME>-base` | Intermediate image from Phase 1 |

Inspect BuildKit cache usage with `docker buildx du`.

## Working with the editor and cooking

Start the container as shown above. Graphics and GUI use of the editor needs extra Docker options (X11 or Wayland forwarding, GPU access, for example `--gpus all`), which depend on your host. For cooking maps from the Digital Twin Tool, follow the CARLA documentation for importing and packaging maps. Depending on your workflow, you may also need `make PythonAPI` inside the container, using the same `Build/` mount.

To keep your own data, mount extra folders (for example, your map files) into the container with additional `-v` options.

## Troubleshooting

**The Unreal Engine `git clone` fails** (for example "repository not found" or an authentication error). Check that your GitHub account is a member of the Epic Games organisation (accept the invitation email or the invitation on GitHub), that `EPIC_USER` and `EPIC_PASS` are correct, and that the token has read access to private repositories.

**Content download fails with HTTP 403.** The original S3 URL for the CARLA content is dead. The script patches it to a mirror. If it still fails, check that the mirror serves the file:

```bash
curl -I https://carla-assets.s3.us-east-005.backblazeb2.com/20231108_c5101a5.tar.gz
```

**A `sed` patch does not apply.** The patch step fails on purpose with a `grep` check, because `sed -i` silently does nothing when its pattern does not match. Note that the Dockerfile is written from a quoted heredoc, so `sed` patterns there use a single backslash (`\.`), not two.

**`aclocal: No such file or directory`.** `automake` is missing. The script installs it in its own small layer after the patches, so the Unreal Engine layers stay cached.

**`fatal: not a git repository ... Stopping at filesystem boundary`.** `GIT_DISCOVERY_ACROSS_FILESYSTEM=1` is not set. The script sets it for Phase 2. Set it yourself when running the image.

**Permission errors on `carla-build/`.** The script runs `chmod 777` on the folder because the container user has uid 1000. On SELinux hosts, add `:z` to the `-v` option.

**A dependency folder in `carla-build/` is half finished** after an interrupted run. Delete only that folder (for example `rm -rf carla-build/patchelf*`) and rerun the script.

**Phase 2 restarts the editor compile.** Phase 2 is not layer-cached. If `make CarlaUE4Editor` fails, the compile starts over on the next run, although `Build/` is reused.

## Notes

- Ubuntu 20.04, clang-10 and Unreal Engine 4.26 are the combination CARLA 0.9.15 expects. Changing them is likely to break the build.
- The script depends on external download locations (GitHub, Backblaze mirrors, SourceForge, boost archives). If one disappears, the corresponding `sed` patch in the Dockerfile section needs updating.
