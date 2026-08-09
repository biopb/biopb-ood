# Installing the BioPB Image Browser

Two deployments, and they differ in more than scale — pick one before you start.

- **[Single user](#a-single-user)** — a sandbox app in your own home, visible only
  to you. Start here, including if you are evaluating the app for a site.
- **[Site-wide or group](#b-site-wide-or-group)** — a system app, one shared biopb
  install, visible to everyone or to one group.

## What both need

**A biopb whose control plane understands `--url-prefix`**
([biopb/biopb#731](https://github.com/biopb/biopb/pull/731)). That is what lets
the UI be served under OnDemand's `/node/<host>/<port>/` path instead of at a
domain root. One command tells you:

```sh
biopb control run --help | grep -- --url-prefix
```

Nothing printed means your biopb predates it: upgrade, or
[build from source](#appendix-building-from-source). This app refuses to start
against a biopb without it rather than letting the session come up blank.

**The CLI and the web bundle from the same release.** A new CLI with an old
bundle starts cleanly and then serves a blank page. It matters more than the
usual version-skew hand-wringing here: the release build used to bake
`VITE_TENSOR_API="/data_plane"` into the bundle, and #731 removed that bake
precisely because a baked value carries no prefix and would silently defeat the
feature. A pre-#731 bundle cannot serve a prefixed origin whatever CLI you pair
with it.

**An OnDemand portal that proxies `/node`** — the default `node_uri`. If yours
differs see [site settings](#5-review-the-site-settings). Do not point this app
at `/rnode/`: that route strips the prefix before the backend sees it, the
opposite of what `--url-prefix` expects.

**Slurm, and a home directory the compute nodes can see.**

---

## A. Single user

### 1. Install biopb

Two routes to the same release. Both put things where the app looks by default,
so leave `BIOPB_BIN_DIR` and `BIOPB_WEBAPP_DIR` unset.

#### The normal install

```sh
curl -sSfL https://biopb.org/install.sh | bash
```

This is what biopb documents for its users. It fetches the current release
bundle and sets up `~/.local` — CLI, control plane, tensor server, and the web
bundle — selecting format support for you (`web,aics,medical,ndtiff`, plus
`bioformats` and `czi` where the platform supports them), which is why images
just open afterwards.

It also installs `napari[all]` — so Qt — and registers biopb-mcp with any AI
agent it detects, rewriting that agent's config. On a workstation that is the
point. On a headless cluster login node it is usually unwanted, which is what the
next route is for.

#### The minimal install

The same release without the desktop stack. Download from the
[release page](https://github.com/biopb/biopb/releases/latest):
`biopb-<v>-py3-none-any.whl`, `biopb_control-<v>-py3-none-any.whl`,
`biopb_tensor_server-<v>-py3-none-any.whl`, `webapp.tar.gz`.

```sh
uv tool install --force ./biopb-<v>-py3-none-any.whl \
  --with "./biopb_tensor_server-<v>-py3-none-any.whl[web,aics,czi,medical,ndtiff]" \
  --with ./biopb_control-<v>-py3-none-any.whl

mkdir -p ~/.local/share/biopb/webapp
tar -xzf webapp.tar.gz --strip-components=1 -C ~/.local/share/biopb/webapp
```

Three things that look like mistakes and are not:

- **The wheel versions do not match each other.** The core `biopb` SDK versions
  independently of the server and control — `release-v0.12.0` ships
  `biopb-0.9.0` alongside `biopb_control-0.12.0`. You have not downloaded the
  wrong file.
- **`uv tool install` links only `biopb` into `~/.local/bin`.** `biopb-control`
  and `biopb-tensor-server` stay inside the tool environment. That is correct:
  the control spawns its data plane as
  `sys.executable -m biopb_tensor_server.cli`, not through `PATH`.
- **You must choose the format extras.** `[web]` alone gives a server that
  starts, indexes your directory, and finds **zero images** — even plain `.tif`,
  which goes through `bioio` and needs `aics`. The full set is `aics`,
  `bioformats`, `czi`, `dicom`, `em`, `hdf5`, `medical`, `ndtiff`, `nifti`,
  `ome-zarr`, `qptiff`; `bioformats` also wants a JVM at run time. (The released
  tensor-server wheel has no `tls` extra even though the source tree does.)

#### Either way, check both halves

```sh
biopb control run --help | grep -- --url-prefix
ls ~/.local/share/biopb/webapp/index.html
```

### 2. Install the app

```sh
git clone https://github.com/biopb/biopb-ood.git \
  ~/ondemand/dev/biopb-image-browser
```

### 3. Launch

In the portal: **Develop → My Sandbox Apps (Development)**, then *BioPB Image
Browser*. Pick a data directory and submit.

The session card shows a **Connect** button — no tunnel. If it does not come
ready, read the job output: every failure this app can anticipate is named there
rather than left as a blank page.

---

## B. Site-wide or group

Everything above applies, plus the following. **Read
[the security note in the README](README.md#what-this-costs-and-why-the-tunnel-branch-still-exists)
before deploying this widely** — it publishes the control plane on the compute
node, and the access token crosses the portal → node hop in cleartext. That is
the same posture as an OnDemand Jupyter app, and it is a decision to make on
purpose rather than inherit.

### 1. Install biopb once, shared

`install.sh` is a per-user installer that targets `~/.local`, so it is not the
tool for this. Put the release wheels in a venv on a path every compute node can
read:

```sh
PREFIX=/apps/biopb/<version>
uv venv --python 3.12 "$PREFIX/venv"
VIRTUAL_ENV="$PREFIX/venv" uv pip install \
  ./biopb-<v>-py3-none-any.whl \
  "./biopb_tensor_server-<v>-py3-none-any.whl[web,aics,czi,medical,ndtiff]" \
  ./biopb_control-<v>-py3-none-any.whl

mkdir -p "$PREFIX/share/biopb/webapp"
tar -xzf webapp.tar.gz --strip-components=1 -C "$PREFIX/share/biopb/webapp"
```

One install serves every user, and it removes the CLI/bundle skew hazard
entirely: both halves can only come from one place.

### 2. Point the app at it

The cluster already uses environment modules and `script.sh.erb` already calls
`module load`, so a modulefile is the natural fit. Have it set **both**
variables, not just `PATH`:

```tcl
prepend-path  PATH              /apps/biopb/<version>/venv/bin
setenv        BIOPB_BIN_DIR     /apps/biopb/<version>/venv/bin
setenv        BIOPB_WEBAPP_DIR  /apps/biopb/<version>/share/biopb/webapp
```

`BIOPB_BIN_DIR` matters even though you set `PATH`: the app prepends that
directory itself, so leaving it unset lets a user's own `~/.local/bin/biopb`
shadow the site install. Setting it makes the site's choice win.

Then add the load beside the existing Java one in `template/script.sh.erb`:

```sh
module load biopb >/dev/null 2>&1 || true
```

Or skip the module and edit the two defaults in `script.sh.erb` directly — a
system app is site-owned, so hardcoding site paths there is legitimate.

A site that sets `XDG_DATA_HOME` in the modulefile instead works too: the app
resolves the bundle location *before* it redirects the XDG dirs per session, so a
module-provided `XDG_DATA_HOME` is honored.

### 3. Install the app system-wide

```sh
git clone https://github.com/biopb/biopb-ood.git \
  /var/www/ood/apps/sys/biopb-image-browser
```

It then appears for every portal user under **Interactive Apps**.

### 4. Restrict it to a group (optional)

To limit it to, say, the microscopy group, use OnDemand's application access
control. The mechanism is version-specific — check your OnDemand documentation
for *Application Access Control* and confirm on the portal host rather than
copying a snippet.

### 5. Review the site settings

| setting | where | note |
|---|---|---|
| Node URI | `template/before.sh.erb` builds `/node/$host/$port` | must match the portal's `node_uri`; a mismatch 404s every request rather than failing visibly |
| Data directory root | `form.yml`, `directory: CurrentUser.home` | **widen this for group shares** — as shipped, users can browse only their own home |
| QOS | form field, default `general` | change the default, or clear it to submit with no `--qos` |
| Cluster | derived from `OodAppkit.clusters` | no edit needed |
| Login host | derived from the cluster's `v2.login.host` | no edit needed; used only for the Arrow Flight tunnel |
| Cache size | form field, default 64 GB | **per session**, on node-local disk. A few concurrent sessions per node will find your real limit; lower it if `/tmp` is small |

### 6. Isolation you get for free

Each session redirects all three XDG base dirs into its own staged job directory,
so concurrent sessions cannot collide over logs, credentials or the session
registry, and no user's stale `~/.config/biopb` or leftover
`~/.local/share/biopb/webapp` can change how their session behaves. See
[Isolation and multi-tenancy](README.md#isolation-and-multi-tenancy).

---

## Verifying, without the portal

OnDemand's `/node/` route passes the path through unchanged, so asking the
compute node for the prefixed URL directly is byte-for-byte what the proxy sends.
From any host that can reach the node:

```sh
curl -s "http://<node>:<control_port>/node/<node>/<control_port>/" | head -12
```

The shell should come back carrying its injected base:

```html
<head><base href="/node/<node>/<control_port>/"><script>window.__BIOPB_BASE__="…";</script>
```

with every asset URL beneath the same prefix. A missing `<base href>` means the
web bundle is older than the CLI.

## Appendix: building from source

Only needed to track biopb's `dev` branch ahead of a release. Requires Python
3.10–3.12, Node 20+, and pnpm 9.

```sh
git clone -b dev https://github.com/biopb/biopb.git ~/src/biopb
cd ~/src/biopb

cd web && pnpm install --frozen-lockfile && pnpm -r run build && cd ..
# -> web/packages/app/dist

uv venv --python 3.12 .venv
VIRTUAL_ENV=.venv uv pip install \
  -e . \
  -e ./biopb-control \
  "./biopb-tensor-server[web,aics,czi,medical,ndtiff]"
```

The leading `./` on the last one is not decoration: `biopb-tensor-server[web]`
parses as a package name with extras and is looked up on PyPI, while
`./biopb-tensor-server[web]` is the local path you just built. The extras
guidance above applies here too — pick them, or index zero images.

Then point the app at the tree instead of `~/.local`:

```sh
BIOPB_BIN_DIR=~/src/biopb/.venv/bin
BIOPB_WEBAPP_DIR=~/src/biopb/web/packages/app/dist
```

Set them in the job environment, or edit the two defaults at the top of
`template/script.sh.erb`.

## When it does not work

| symptom | cause |
|---|---|
| Job exits at once, "does not support `--url-prefix`" | biopb predates #731 — upgrade, or use this app's `main` branch, which tunnels instead |
| Page loads blank, console 404s on `/assets/*` | CLI and bundle are from different releases |
| Portal says 503 / failed to connect | the control did not bind the node's interfaces; check `BIOPB_CONTROL_HOST` in the job output |
| Every request 404s | the portal's `node_uri` is not `/node` |
| Catalog stays empty, `source_count: 0` | missing format extras |
| `401 Unauthorized` | open the Connect button from the card; it carries the token |

Job output lands in the session directory under
`~/ondemand/data/sys/dashboard/batch_connect/`.
