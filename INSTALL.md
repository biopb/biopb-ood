# Installing the BioPB Image Browser

Two deployments, and they differ in more than scale — pick one before you start.

- **[Single user](#a-single-user)** — a sandbox app in your own home, visible only
  to you. Start here, including if you are evaluating the app for a site.
- **[Site-wide or group](#b-site-wide-or-group)** — a system app, one shared biopb
  install, visible to everyone or to one group.

## What both need

**biopb 0.13.0 or newer** — the release whose control plane understands
`--url-prefix` ([biopb/biopb#731](https://github.com/biopb/biopb/pull/731)),
which is what lets the UI be served under OnDemand's `/node/<host>/<port>/` path
instead of at a domain root. Rather than compare version strings, ask the CLI:

```sh
biopb-control run --help | grep -- --url-prefix
```

Nothing printed means your biopb is too old: upgrade, or
[build from source](#appendix-building-from-source). This app refuses to start
against a biopb without the flag rather than letting the session come up blank.
On 0.12.0 or earlier, use this app's [`tunnel`](../../tree/tunnel) branch, which
reaches the same session over SSH and needs nothing from the portal.

**biopb 0.15.0 or newer** (the first release containing
[biopb/biopb#1158](https://github.com/biopb/biopb/issues/1158)) —
the release whose control plane understands `--grpc-external-location`, which
is what makes the Arrow Flight address this app hands out (the session card,
and any `SerializedTensor`/dask graph the server forwards) match the address a
remote client can actually dial, instead of whatever loopback-remapped address
the server happened to dial itself with internally. Unlike `--url-prefix`
above, `script.sh.erb` does not probe the CLI for this flag at launch: this app
is versioned as a single unit against a specific biopb baseline (see "The CLI
and the web bundle from the same release" below), so the requirement is
enforced by that pairing, not by a second runtime check for a flag that will
always be present or always absent together with `--url-prefix` on any release
built from 0.15.0 on.

**The CLI and the web bundle from the same release.** A new CLI with an old
bundle starts cleanly and then serves a blank page. It matters more than the
usual version-skew hand-wringing here: builds before 0.13.0 baked
`VITE_TENSOR_API="/data_plane"` into the bundle, and #731 removed that bake
precisely because a baked value carries no prefix and would silently defeat the
feature. A pre-0.13.0 bundle cannot serve a prefixed origin whatever CLI you
pair with it.

**An OnDemand portal that proxies `/node`** — the default `node_uri`. If yours
differs see [site settings](#5-review-the-site-settings). Do not point this app
at `/rnode/`: that route strips the prefix before the backend sees it, the
opposite of what `--url-prefix` expects.

Check it against a working interactive app rather than assuming, because both
ways it can fail look identical from the browser — a plain Apache **404**, with
`Server at … Port 443` in the footer and nothing in the job output:

```sh
# an existing app's Connect link tells you both halves at once
https://portal.example.edu/node/node042.cluster.example.edu/8888/lab
#                          ^^^^ node_uri   ^^^^^^^^^^^^^^^^^^^^^^^ the host form
```

If that link carries a fully qualified name, the portal's `host_regex` wants
one, and `before.sh.erb` supplies it (`hostname -f`). If it carries a short
name and your nodes report a domain, drop that block — see
[site settings](#5-review-the-site-settings). If no app on the portal has a
`/node/…` link at all, the node proxy is probably not enabled: an unauthenticated
`curl -o /dev/null -w '%{http_code}' https://portal/node/` answers `404` when the
route is absent, `302` when it exists and merely wants a login.

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
  independently of the server and control, so its wheel carries an unrelated
  number — `release-v0.12.0` shipped `biopb-0.9.0` next to
  `biopb_control-0.12.0`, and `release-v0.13.0rc1` shipped a `biopb-0.8.1.dev…`
  build next to `biopb_control-0.13.0rc1`. Take whatever the release page lists;
  you have not downloaded the wrong file.
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
biopb-control run --help | grep -- --url-prefix
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

### 4. JupyterLab and an agent terminal (optional)

Set **JupyterLab and agent terminal** to Yes on the launch form. The app does not
install JupyterLab; it looks for one on the compute node, in this order:

1. `BIOPB_OOD_JUPYTER` — the path to a `jupyter-lab` executable.
2. The user's own: `jupyter-lab` on `PATH`, then `~/.local/bin`.
3. The environment module named in the form's *JupyterLab module* field,
   prefilled from `BIOPB_OOD_JUPYTER_MODULE` in the portal's environment.

The module is tried last, so a JupyterLab the user installed is never shadowed by
the site's.

Most portals already have one for their own Jupyter app, and that is the one to
use. Failing that, a separate tool environment is enough — do not add it to
biopb's:

```sh
uv tool install jupyterlab
```

A module-installed Jupyter (Spack, Lmod) often lacks the config files that switch
on server extensions, so the Lab comes up with no Terminal even though the package
is there. The app turns the terminal extension on unless the Lab's own
configuration already names it, so a site that enabled it is left alone and one
that disabled it (`jpserver_extensions`) is not overridden. Setting
`terminals_enabled = False` in the site's Jupyter config turns terminals off
regardless.

The session card also links OnDemand's own shell app for the node
(`/pun/sys/shell/ssh/<node>`), whether or not JupyterLab is on. That is the
portal's terminal, so whether it will open a compute node is the site's host
allowlist (`OOD_SSHHOST_ALLOWLIST`); if it refuses, the card's text points at plain
`ssh`. It assumes the default `/pun/sys/shell` mount.

If none is found the session starts without it and the card says so; the viewer
is unaffected. The notebook kernel *biopb: connect to the running biopb session*
comes from biopb's own installer (skipped by `BIOPB_INSTALL_KERNELSPEC=0`), and
runs in biopb's environment, so the Jupyter you point at needs nothing from biopb.

See [README.md](README.md#jupyterlab-and-an-agent-terminal) for what it starts.

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

A site that sets `BIOPB_DATA_HOME` in the modulefile instead works too: the app
resolves the bundle location from the launching user's environment, so a
module-provided `BIOPB_DATA_HOME` is honored (a legacy `XDG_DATA_HOME` is still
read as a fallback here, though biopb itself no longer honors it — see
biopb/biopb#790).

**`BIOPB_OOD_FLIGHT_HOST`**, set the same way, overrides the hostname a remote
Flight session advertises (`flight_url`, and thus `--grpc-external-location`)
without changing the name the portal itself uses to reach the node. Needed only
when a compute node's interconnect (Infiniband/RoCE) is named differently from
the `hostname -f` name the portal proxies through — e.g. `node03-ib` vs.
`node03.cluster.example.edu` — so that a dask worker on another node dials the
faster network instead of routing back through the management interface.
Leave it unset unless you have observed that split on your cluster.

**`BIOPB_OOD_JUPYTER`** and **`BIOPB_OOD_JUPYTER_MODULE`** name the site's
JupyterLab for the optional JupyterLab feature (see
[A.4](#4-jupyterlab-and-an-agent-terminal-optional)). Set the module (in the
portal's environment, where it prefills the form; a user can still change it),
and the path if the module does not put `jupyter-lab` on `PATH`. The module is loaded
around the Lab process only, so its `PYTHONPATH` never reaches biopb.
**`BIOPB_OOD_JUPYTER_ORIGIN_PAT`** is for a portal whose proxy does not preserve
the `Host` header: Lab then loads but its kernels and terminals fail with a
403, and a regular expression for the portal's origin (e.g.
`https://portal\.example\.edu`) is passed as `allow_origin_pat`.

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
| Portal origin | `BIOPB_PUBLIC_ORIGIN`, in the portal's environment (`pun_custom_env` in `nginx_stage.yml`) or the job's | your portal's `https://host[:port]`, as a browser addresses it. **Optional but worth setting**: it is what lets an agent in the session's terminal hand the user a viewer link that opens, instead of a path on "the portal you opened". Needs **biopb 0.15.2 or newer** (the first release with `--public-origin`, biopb/biopb#1195); an older one ignores it. A malformed value is dropped with a warning in the job log, not a failed session |
| Node name form | `template/before.sh.erb`, the `hostname -f` block | the prefix must use the name the portal's `host_regex` accepts. Qualified is the common case and the default here; a site whose regex wants short names should delete the block. Wrong form = Apache 404, nothing reaches the node |
| Data directory root | `form.yml.erb`, `directory:` | **widen this for group shares** — as shipped, users can browse only their own home |
| Data directory default | `form.yml.erb`, `biopb_data_dir` in the ERB preamble | `~/data` when the user has one, else their home. Point it at your site's convention (a group share, `/scratch/$USER`) — home is the safe answer, not a good one, since the scan then walks everything under it |
| QOS | form field, default `general` | change the default, or clear it to submit with no `--qos` |
| Cluster | derived from `OodAppkit.clusters` | no edit needed |
| Login host | derived from the cluster's `v2.login.host` | no edit needed; used only for the Arrow Flight tunnel, and only when the launch form asks for loopback Flight |
| Arrow Flight access | form field, default remote (`grpcs://` on the node) | flip the default to `"false"` in `form.yml.erb` if your site firewalls compute nodes off from user workstations, or does not want the port published at all. See [Remote Arrow Flight](README.md#remote-arrow-flight) |
| JupyterLab | form field, default off | needs a JupyterLab the app can find; see [A.4](#4-jupyterlab-and-an-agent-terminal-optional). Uses the port after Flight (`base+6`), so a firewall that only opens the first three needs that one too |
| Exclusive node | form field, default off | adds `--exclusive` when JupyterLab is on. **Read the security note in the README before turning JupyterLab on for a shared-node cluster** |
| Cache size | form field, default 64 GB | **per session**, on node-local disk. A few concurrent sessions per node will find your real limit; lower it if `/tmp` is small |

### 6. Isolation you get for free

Not by giving each session its own tree — biopb's state (`~/.config/biopb`,
`~/.local/state/biopb`, `~/.local/share/biopb`) is a singleton by construction,
one `control.pid`/credential/session-registry per account, so this app leaves it
exactly where biopb puts it, unredirected, in the launching user's own home.

What that buys a shared, site-wide install specifically:

- **Different users sharing a compute node** are isolated from each other by
  having separate home directories to begin with — nothing about a shared
  `/apps/biopb/<version>` install changes that. The access token is what keeps
  one user's data out of another's reach on the ports that *are* shared (the
  control port is open on the node's interfaces; the sidecar and Flight ports,
  though loopback-only, are reachable by every other user logged in to the same
  node).
- **The same user launching twice** is refused outright — `before.sh.erb` checks
  Slurm (`squeue -u $USER -n biopb-browser`), not `control.json`, so a `scancel`
  or OOM kill can't wedge the guard open. One session per user is the trade this
  app makes instead of per-session isolation; the token and TLS certificate stay
  stable across relaunches and nodes as a direct consequence.

See [Isolation and multi-tenancy](README.md#isolation-and-multi-tenancy) for the
full mechanics.

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
| The app opens with no form: "This app requires clusters that do not exist or you do not have access to" | the form file lost its `.erb` extension (the dashboard then never renders it), or the cluster genuinely is not in `/etc/ood/config/clusters.d` / not one you may submit to |
| Job exits at once, "does not support `--url-prefix`" | biopb is older than 0.13.0 — upgrade, or use this app's [`tunnel`](../../tree/tunnel) branch, which tunnels instead |
| Page loads blank, console 404s on `/assets/*` | CLI and bundle are from different releases |
| Portal says 503 / failed to connect | the control did not bind the node's interfaces; check `BIOPB_CONTROL_HOST` in the job output |
| Every request 404s | the portal's `node_uri` is not `/node` |
| Catalog stays empty, `source_count: 0` | missing format extras |
| `401 Unauthorized` | open the Connect button from the card; it carries the token |

Job output lands in the session directory under
`~/ondemand/data/sys/dashboard/batch_connect/`.
