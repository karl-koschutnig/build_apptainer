# bids_apptainer_autobuild

Daily checker that polls Docker Hub for new **full releases** of a small set
of BIDS apps and builds any missing ones into Apptainer `.sif` images, using
a vendored copy of `bids_apps_runner`'s `build_apptainer.sh`.

It exists because building these images directly on the HPC is tricky
(disk/tmp constraints there), so images are built here on
`/data/local/container/` and then used on the HPC.

## Quick setup

Six things to configure, in order. Everything else in this README is
background/design notes you can read later.

1. **Configure your paths — `config/paths.env`.** Required before any
   script here will run — there's no implicit `/data/local` default baked
   in:
   ```
   cp config/paths.env.example config/paths.env
   $EDITOR config/paths.env   # set CONTAINER_DIR, TMP_BASE, DISK_CHECK_PATH,
                              # MIN_FREE_GB, DSISTUDIO_BUILD_SCRIPT, DSISTUDIO_IMAGES_DIR
   ```
   `bin/check_and_build.sh`, `bin/sync_images_all.sh`, and
   `bin/sync_datalad.sh` all read this file and refuse to run without it.
   Also use a matching path in `config/apps.conf`'s `output_dir` column
   (step 2) — that file is independently edited, not driven by
   `config/paths.env`.

2. **Choose which Docker images to track — `config/apps.conf`.**
   One `name | docker_repo | tag_regex | output_dir` line per app (see the
   header comment in the file for the exact field meanings). Add, remove,
   or edit lines freely; no code changes needed. `output_dir` is created
   automatically on first build, nothing to `mkdir` up front.

3. **Apptainer build tmp space.**
   All build tmp/cache (`APPTAINER_TMPDIR`, `SINGULARITY_CACHEDIR`, etc.)
   goes under `TMP_BASE` from step 1 — set it to a path with enough room
   for the largest image you're building (several GB per app), never the
   system default `/tmp` or `$HOME`.

4. **Output layout.**
   Each app lands as `<output_dir>/<image>_<tag>.sif` (e.g.
   `qsirecon_26.0.0.sif`), one `output_dir` per app as set in
   `config/apps.conf`. Run `bin/sync_images_all.sh` any time afterward to
   hardlink every built `.sif` into one flat lookup directory (see
   "Consolidated image directory" below) if you want a single place to
   find any image regardless of which app subfolder it's under.

5. **Push notifications — ntfy.sh.**
   ```
   cp config/ntfy.env.example config/ntfy.env
   chmod 600 config/ntfy.env
   $EDITOR config/ntfy.env   # set NTFY_TOPIC to a long random string
   ```
   See "Push notification on new builds" below for the full explanation.
   Skip this and the script just logs "not configured yet" and continues.

6. **Cron job.**
   ```
   30 4 * * * /path/to/build_apptainer/bin/check_and_build.sh >> /path/to/build_apptainer/logs/cron.log 2>&1
   ```
   Adjust the time and the two `/path/to/build_apptainer` paths for your
   clone location, then `crontab -e` and add the line.

Datalad sync (pushing built images to a separate datalad/rsync server) is
**optional** and specific to MRI-Lab Graz's own infra — see "Syncing new
builds to the datalad server" below. If you don't set up
`config/datalad.env`, that step is silently skipped and nothing else is
affected.

DSI Studio is a different story: it's a special-cased app hardcoded into
`bin/check_and_build.sh` (not a `config/apps.conf` row) that expects an
external build script at the path in `DSISTUDIO_BUILD_SCRIPT`. If you don't
have that script, either point `DSISTUDIO_BUILD_SCRIPT` at your own copy or
remove/stub out `process_dsistudio` — otherwise *every* run will log an
error and exit non-zero. See "DSI Studio (special case, not in
`apps.conf`)" below for the full explanation.

## Hard constraint: nothing writes to the system device

`/` is a small, separate device from `/data/local` (see `df -h`) and is not
meant to absorb build traffic -- **every process this repo runs, and
everything it builds, must live under `/data/local`.** This includes not
just final `.sif` output but every intermediate: Apptainer/Singularity
tmp+cache dirs, `mksquashfs` scratch space, `mktemp` calls, downloaded
release assets, log files, everything. Never rely on a tool's default
(often system `/tmp` or `$HOME`) without explicitly overriding it.

Already-verified compliant:
- `TMP_BASE` (from `config/paths.env`) and `STATE_DIR`/`LOG_DIR`
  (repo-relative) in `bin/check_and_build.sh`, and its
  `state_tmp=$(mktemp -p "$STATE_DIR")` (not a bare `mktemp`, which defaults
  to system `/tmp`).
- `vendor/build_apptainer.sh`'s per-build `APPTAINER_TMPDIR`/`TMPDIR`/
  `APPTAINER_CACHEDIR`/`SINGULARITY_CACHEDIR`, all under the `-t` path it's
  given (`TMP_BASE`).
- `installation/apptainer/build_image.sh` (DSI Studio) sets the same four
  env vars under `TMP_BASE` too before invoking `apptainer build`.

When adding new tooling here, check every `mktemp`, every temp/cache env
var a called binary respects, and any implicit default path before trusting
it -- verify with `df -h` / by watching `/`'s usage during a real run, not
just by reading the code.

## What it tracks

See [`config/apps.conf`](config/apps.conf) — currently fMRIPrep, QSIPrep,
QSIRecon, MRIQC, FreeSurfer, FastSurfer (CUDA build), BIDS Validator,
MRtrix3_connectome, Giga Connectome, RS-HRF, and Hipsta, each pointed at
its actively-maintained Docker Hub org.

For fMRIPrep/QSIPrep/QSIRecon/MRIQC/FreeSurfer/FastSurfer that's *not* the
`bids/` org on Docker Hub (see "Why not `hub.docker.com/u/bids`" below).
The other four genuinely are current under `bids/` (checked directly by
sorting all 46 repos in that org by last-updated): `bids/validator`
(2026-07-20), `bids/mrtrix3_connectome` (0.6.0, 2025-06), `bids/giga_connectome`
(0.6.0, 2025-05), `bids/rshrf` (v1.7.0, 2026-05). Most of the rest of the
`bids/` org is either stale (no real release in years, even if an
`unstable` tag gets rebuilt periodically — e.g. `brainsuite`, `spm`,
`cat12`), a base/template image (`base_*`, `example`), or abandoned
outright (2016-2019).

`bids/pymvpa` was checked and deliberately excluded: its tag history isn't
monotonic (`v2.0.2` pushed 2026-07 sorts *lower* than the pre-existing
`v4.0.4` from 2024), so "highest version = newest" would pick the wrong
tag. Add it manually if you ever need it, not through this automation.

Hipsta (`deepmi/hipsta`, same org as FastSurfer) has exactly one Docker Hub
tag (`0.10.1`, pushed 2026-07-06) -- no interactive "which BIDS App" preset
list to add it to, just a config line, since a plain semver tag already
matches the default filter. The pre-existing local build under
`/data/local/container/hipsta/` (`dockerfile.sif`) came from a custom
Dockerfile, not this pipeline -- it's left alone; the versioned build lands
alongside it as `hipsta_0.10.1.sif`.

Add a new app by adding one line to `config/apps.conf`: name, Docker repo,
a regex that matches only "full release" tags for that app, and the output
directory. No code changes needed.

## DSI Studio (special case, not in `apps.conf`)

DSI Studio is checked/built too, but it's hardcoded into
`bin/check_and_build.sh` (`process_dsistudio()`) instead of being a
`config/apps.conf` row, because it doesn't fit that model:

- **No Docker Hub tags to poll.** `dsistudio/dsistudio` on Docker Hub exists
  and is actively maintained, but it's a **CPU-only** build. GPU-accelerated
  tractography needs CUDA, so this pipeline instead wraps the maintainer's
  prebuilt Linux release asset (CUDA-enabled) — see `installation/apptainer/dsi_studio.def` alongside the build script at `DSISTUDIO_BUILD_SCRIPT` (`config/paths.env`).
- **GitHub release tags don't reliably ship that asset.** The maintainer's
  release workflow builds Windows/Linux/Mac/Docker as independently
  toggleable jobs; e.g. the newest release as of 2026-08 (`2026.7.25`) is
  Windows-only. The Linux CUDA zip instead lives permanently under an older
  tag (`2025.04.16`) and gets refreshed there via `gh release upload
  --clobber` on almost every CI run, so a plain `/releases/latest/download/`
  URL breaks whenever a newer tag without that asset gets cut (this is what
  broke the old weekly cron job for months). `build_image.sh` now walks
  releases newest-first via the GitHub API and uses whichever one currently
  has the asset.
- **Output location and naming can't move.** Individual analysis projects
  pin to a specific `<DSISTUDIO_IMAGES_DIR>/dsi_studio/dsi_studio_hou-
  <date>.sif` (`DSISTUDIO_IMAGES_DIR` from `config/paths.env`), recorded in
  each project's own `code/dsistudio/dsi_studio_image.json`, and
  `build_image.sh` must never overwrite an existing dated image. So unlike
  every other app here, this one keeps its existing output dir instead of
  moving under `CONTAINER_DIR`, and versioning is by the build date
  embedded in the binary itself (`dsi_studio --version`), not a Docker tag
  or Git ref.

It still plugs into the same logging, `state/versions.json`, ntfy
notification, and (for the `CONTAINER_DIR` tree) datalad-sync machinery as
everything else — it's just checked and named differently. One gap:
`bin/sync_datalad.sh` only mirrors `CONTAINER_DIR`, so new DSI Studio
builds under `DSISTUDIO_IMAGES_DIR/dsi_studio/` are *not* pushed to the
datalad server by this pipeline.

## Consolidated image directory

After every real (non-dry-run) `check_and_build.sh` run, `bin/sync_images_all.sh`
hardlinks every real, on-disk `.sif` -- every `config/apps.conf` app under
`CONTAINER_DIR/*/` plus every DSI Studio image under
`DSISTUDIO_IMAGES_DIR/dsi_studio/` -- into one flat directory,
`DSISTUDIO_IMAGES_DIR/all/`, so nobody has to know which per-app subfolder
a given image lives under. (`CONTAINER_DIR` and `DSISTUDIO_IMAGES_DIR` are
both set in `config/paths.env`.)

It's pure addition, safe to re-run any time (`bin/sync_images_all.sh` by
itself): a hardlink is just another name for an existing inode, so this
never moves, renames, deletes, or overwrites any original file, and can't
affect any project's pinned image path (e.g. dsistuido's
`dsi_studio_image.json`) or cause an in-progress analysis to switch
versions mid-project. `*_latest.sif` *symlinks* (currently only
`dsi_studio_latest.sif`) are deliberately skipped -- this directory is for
picking a specific pinned build, not a moving "latest" target. Note that a
few apps (`bidspm_latest.sif`, `fastsurfer_gpu-latest.sif`) have a real,
static file literally named `*_latest.sif` rather than a symlink -- those
aren't skipped, only actual symlinks are.

## Why not `hub.docker.com/u/bids`?

Checked directly: `bids/fmriprep` and `bids/mriqc` exist there but haven't
been updated since 2018 (old community images), and `bids/qsiprep`,
`bids/qsirecon`, `bids/fastsurfer` don't exist under that org at all. The
images actually in use here (and already built under
`/data/local/container/`) come from `nipreps/`, `pennlinc/`,
`freesurfer/`, and `deepmi/` instead — that's what this repo tracks.

## "Full release" filtering

Each app's `tag_regex` in `config/apps.conf` is the filter. Docker Hub tags
like `latest`, `unstable`, `experimental`, `premask`, or `25.0.0rc0` are
excluded automatically because they don't match a strict tag pattern (pure
`X.Y.Z` semver for most apps; `cuda-vX.Y.Z` for FastSurfer, matching the
GPU builds already in use here; `v?X.Y.Z` for RS-HRF, whose tags switched
from unprefixed to `v`-prefixed partway through its history). Of the
matching tags, the highest by version sort (`sort -V`) is treated as
"latest full release" -- for RS-HRF specifically this is safe long-term
because `v` (0x76) always sorts after any digit (0x30-0x39) in ASCII, so a
future `vX.Y.Z` release will always outrank an older unprefixed one
regardless of the numbers involved.

## How "already built" is detected

There's no separate manifest/database -- the filesystem is the source of
truth, matching the existing convention under `/data/local/container/`.
For a given app + tag, the script looks for `<image>_<tag>.sif` **or**
`<image>-<tag>.sif` in the app's output dir (the existing builds are
inconsistent about the separator, e.g. `freesurfer-8.2.0.sif` vs
`qsirecon_1.2.0.sif` -- both are recognized so nothing gets wastefully
rebuilt).

## Checking for updates without a build

Every run (dry-run or real) refreshes `state/versions.json`, a small
per-app status file -- the Docker Hub tag fetch already happens on every
run regardless, so this is just recording what was found:

```json
"qsirecon": {
  "docker_repo": "pennlinc/qsirecon",
  "latest_available": "26.0.0",
  "installed": "26.0.0",
  "installed_sif": "/data/local/container/qsirecon/qsirecon_26.0.0.sif",
  "status": "up_to_date",
  "last_checked": "2026-07-28T13:57:04Z"
}
```

`status` is one of `up_to_date`, `update_available` (found on Docker Hub,
not built yet), `built` (built this run), `build_failed`,
`no_tags_matched` (nothing on Docker Hub matches `tag_regex` -- config
problem, not a real gap), or `fetch_error` (Docker Hub/network issue).

It's not a source of truth (the filesystem still is -- this file is
rebuilt from scratch every run and gitignored) -- it's there so you can
answer "is anything out of date?" with a `cat`/`jq` instead of re-running
the whole check:

```
jq -r 'to_entries[] | select(.value.status != "up_to_date") | "\(.key): \(.value.installed // "none") -> \(.value.latest_available)"' state/versions.json
```

## Running it

```
bin/check_and_build.sh --dry-run   # report what would be built, no build/API side effects beyond the tag fetch
bin/check_and_build.sh             # actually build anything missing
```

It also aborts the whole run before touching Docker Hub if `DISK_CHECK_PATH`
has less than `MIN_FREE_GB` free (both set in `config/paths.env`; on this
server's setup that's `/data/local`, already at ~98% usage as of 2026-07).

### Concurrency: builds within a run, and across cron runs

Within a single run, apps are processed **one at a time, in the order
they appear in `config/apps.conf`** -- if three apps all need a build,
they build sequentially, not in parallel (`build_apptainer.sh` itself
also builds one image per invocation).

Across runs: the script takes an `flock -n` lock on `logs/.lock` at
startup. If cron fires while a previous run (manual or cron) is still
building something, the new invocation logs `SKIP: another run is
already in progress` and exits immediately -- it does **not** queue, wait,
or run concurrently. Nothing is lost: the next day's 04:30 run re-checks
Docker Hub from scratch and picks up anything still missing. If you want
to force a check sooner after a skip, just run `bin/check_and_build.sh`
by hand once the in-progress build finishes.

All build temp/cache files go under `TMP_BASE` (`config/paths.env`,
per-build subfolder, cleaned up by `build_apptainer.sh` itself on
success) -- never under `$HOME` or the primary/root filesystem.

Logs: `logs/build.log` (rolling, timestamped, written by this script) and
`logs/cron.log` (raw stdout/stderr capture from the cron invocation).

## Push notification on new builds

When a run actually builds one or more new images, it sends a summary via
`bin/notify_ntfy.sh` to [ntfy.sh](https://ntfy.sh) -- no account, password,
or SMTP auth needed, just curl POSTing to a topic URL. Set up once:
```
cp config/ntfy.env.example config/ntfy.env
chmod 600 config/ntfy.env
$EDITOR config/ntfy.env   # set NTFY_TOPIC to a long random string, see the file's comments
```
Then subscribe to that topic in the [ntfy app](https://ntfy.sh) (iOS/Android)
or by opening `https://ntfy.sh/<your-topic>` in a browser.

`config/ntfy.env` is gitignored (the topic name is effectively a shared
secret -- anyone who knows it can publish to or read it) and is not
created automatically -- without it, `notify_ntfy.sh` just logs "not
configured yet" and the run continues normally (notification is
best-effort, a missing/failing send never fails the build).

Test the topic directly without waiting for a real build:
```
echo "test body" | bin/notify_ntfy.sh "test subject"
```

### Why not email

Email was tried first, via SMTP against Uni Graz's mail server
(`email.uni-graz.at`, Microsoft Exchange). It hit a wall: the server
rejects plain username/password SMTP auth (`535 5.7.3 Authentication
unsuccessful`), most likely because MFA/Modern Auth is enforced and an
app-specific password would be needed instead of the regular account
password. Rather than fight institutional auth policy for a build
notification, ntfy.sh sidesteps the whole problem.

## Syncing new builds to the datalad server

**Optional** — specific to MRI-Lab Graz's own datalad mirror, most users
can skip this whole section. When a run builds one or more new images and
`config/datalad.env` exists, it also pushes the local container store
(`CONTAINER_DIR`, from `config/paths.env`) to the datalad server via
`bin/sync_datalad.sh`, using
`rsync -a --ignore-existing` (only adds files missing on the receiver --
never overwrites or deletes anything already there). Set up once:
```
cp config/datalad.env.example config/datalad.env
chmod 600 config/datalad.env
$EDITOR config/datalad.env   # set DATALAD_USER/HOST/PATH, see the file's comments
```
Requires passwordless (key-based) SSH from this host to
`DATALAD_USER@DATALAD_HOST` already set up.

`config/datalad.env` is gitignored and not created automatically --
without it, `sync_datalad.sh` just logs "not configured yet" and the run
continues normally. Unlike notifications, a failed sync marks the overall
run as failed (exit status 1) so it's not silently missed.

Run it manually any time without waiting for a new build:
```
bin/sync_datalad.sh
```

## The vendored build script

`vendor/build_apptainer.sh` is a vendored, lightly-patched copy of
[`bids_apps_runner`'s `scripts/build_apptainer.sh`](https://github.com/MRI-Lab-Graz/bids_apps_runner/blob/main/scripts/build_apptainer.sh).
See [`vendor/SOURCE.md`](vendor/SOURCE.md) for exactly what was changed and
why (short version: upstream's `--docker-repo` flag is silently ignored in
the Docker Hub build path, which would otherwise hang forever under cron
waiting on an interactive menu). It was vendored rather than pointed at the
`bids_apps_runner` checkout at `/data/local/container/code/bids_apps_runner/`
because that checkout is very outdated and pre-dates the non-interactive
flags this automation depends on.

## Cron

```
30 4 * * * /data/local/software/build_apptainer/bin/check_and_build.sh >> /data/local/software/build_apptainer/logs/cron.log 2>&1
```

Daily at 04:30. This also covers DSI Studio now (see above) — the separate
weekly Sunday 03:00 `dsistudio` cron job that used to call
`build_image.sh` directly was removed since this run supersedes it.
