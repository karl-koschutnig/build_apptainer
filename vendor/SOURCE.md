## Provenance

`build_apptainer.sh` in this directory is vendored from:

https://raw.githubusercontent.com/MRI-Lab-Graz/bids_apps_runner/main/scripts/build_apptainer.sh

fetched from `main` at commit `0853a86` (2026-07-28).

It is vendored rather than symlinked/referenced from the `bids_apps_runner`
checkout at `/data/local/container/code/bids_apps_runner/` because that
checkout is currently ~580 commits behind `origin/main` and has one
unpushed local commit (`ab48a9e add some checks`) — its `build_apptainer.sh`
predates the `--docker-repo`/`--docker-tag` non-interactive flags entirely
and is still fully interactive. Vendoring avoids touching that repo's
history.

### Local patch

One patch on top of upstream, in the "Docker Hub Branch" section: upstream
parses `--docker-repo` into `DOCKER_REPO_OVERRIDE` but never applies it in
the Docker Hub branch — the `select APP` menu ran unconditionally, which
hangs forever under cron (no TTY to read from). Patched to skip the menu
when `--docker-repo` is provided, mirroring the identical guard already
used a few lines up in the `-d DOCKERFILE` branch. Search for `PATCHED
(bids_apptainer_autobuild` in the script for the exact change.

Worth upstreaming this one-line-guard fix to `bids_apps_runner` itself at
some point, independent of this repo.

### Updating the vendored copy

Re-fetch from the URL above, re-apply the same patch (or diff against this
file's git history to see exactly what changed), and re-verify
`--docker-repo`/`--docker-tag` still work non-interactively before
replacing.
