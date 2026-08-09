# Installing the BioPB Image Browser

Two deployments, and they differ in more than scale — pick one before you start.

- **[Single user](#a-single-user)** — a sandbox app in your own home, visible only
  to you. This is the one to start with, including if you are evaluating the
  app for a site.
- **[Site-wide or group](#b-site-wide-or-group)** — a system app, one shared biopb
  install, visible to everyone (or to one group).

## What both need

**A biopb carrying [biopb/biopb#731](https://github.com/biopb/biopb/pull/731).**
That PR added `--url-prefix`, which is what lets the control plane be served
under OnDemand's `/node/<host>/<port>/` path. It is on biopb's `dev` branch and
**is not in any release**, so this branch cannot be installed from
`install.sh` yet — you have to build it. (The `main` branch of this app needs no
such build; it tunnels instead and works against 0.12.0.)

Both halves — the CLI *and* the web bundle — must come from the same tree. A new
CLI with an old bundle starts cleanly and then serves a blank page.

**An OnDemand portal that proxies `/node`.** The default `node_uri`. If yours
differs, see [Site settings](#5-review-the-site-settings). Do not point this app
at `/rnode/`; that route strips the prefix before the backend sees it, which is
the opposite of what `--url-prefix` expects.

**Slurm, and a home directory the compute nodes can see.**

---

## A. Single user

### 1. Build biopb

Needs Python 3.10–3.12, Node 20+, and pnpm 9. Nothing here writes outside the
tree you clone.

```sh
git clone -b dev https://github.com/biopb/biopb.git ~/src/biopb
cd ~/src/biopb

# The web bundle.
cd web && pnpm install --frozen-lockfile && pnpm -r run build && cd ..
# -> web/packages/app/dist

# The Python side.
uv venv --python 3.12 .venv
VIRTUAL_ENV=.venv uv pip install \
  -e . \
  -e ./biopb-control \
  "./biopb-tensor-server[web,aics,czi,medical,ndtiff]"
```

The leading `./` on the last one is not decoration: `biopb-tensor-server[web]`
parses as a package name with extras and is looked up on PyPI, while
`./biopb-tensor-server[web]` is the local path you just built.

**Choose your format extras deliberately.** `[web]` alone gives you a server that
starts, indexes your directory, and finds **zero images** — even plain `.tif`,
which goes through `bioio` and needs `aics`. The full set is `aics`,
`bioformats`, `czi`, `dicom`, `em`, `hdf5`, `medical`, `ndtiff`, `nifti`,
`ome-zarr`, `qptiff`. Add what your data needs; `bioformats` additionally wants a
JVM at run time.

Check both halves:

```sh
.venv/bin/biopb control run --help | grep -- --url-prefix   # must print something
ls web/packages/app/dist/index.html
```

### 2. Install the app

```sh
git clone -b dev https://github.com/biopb/biopb-ood.git \
  ~/ondemand/dev/biopb-image-browser
```

The app finds biopb through two variables, both defaulting to the installer's
locations. Point them at the tree you just built — edit the two lines at the top
of `template/script.sh.erb`, or export them in your shell profile:

```sh
BIOPB_BIN_DIR=~/src/biopb/.venv/bin
BIOPB_WEBAPP_DIR=~/src/biopb/web/packages/app/dist
```

If instead you install biopb properly into `~/.local` once #731 ships, leave both
unset and the defaults are correct.

### 3. Launch

In the portal: **Develop → My Sandbox Apps (Development)**, then
*BioPB Image Browser*. Pick a data directory and submit.

The session card shows a **Connect** button — no tunnel. If it does not appear
ready, read the job output; every failure this app can anticipate is named there
rather than left to a blank page.

---

## B. Site-wide or group

Everything in part A applies, plus the following. **Read
[the security note in the README](README.md#what-this-costs-and-why-the-tunnel-branch-still-exists)
before deploying this widely** — it publishes the control plane on the compute
node and the access token crosses the portal → node hop in cleartext. That is the
same posture as an OnDemand Jupyter app, and it is a decision to make on purpose.

### 1. Install biopb once, shared

Build exactly as in A.1, into a path every compute node can read
(`/apps/biopb/<version>`, or wherever your site puts software). One install
serves every user, and it removes the CLI/bundle version-skew hazard entirely,
since both halves can only come from one place.

### 2. Point the app at it

The cluster already uses environment modules, and `script.sh.erb` already calls
`module load`, so a modulefile is the natural fit. Have it set **both**
variables, not just `PATH`:

```tcl
prepend-path  PATH              /apps/biopb/0.13/bin
setenv        BIOPB_BIN_DIR     /apps/biopb/0.13/bin
setenv        BIOPB_WEBAPP_DIR  /apps/biopb/0.13/share/biopb/webapp
```

`BIOPB_BIN_DIR` matters even though you set `PATH`: the app prepends that
directory itself, so with it unset a user's own `~/.local/bin/biopb` would shadow
the site install. Setting it makes the site's choice win.

Then add the load next to the existing Java one in `template/script.sh.erb`:

```sh
module load biopb >/dev/null 2>&1 || true
```

Alternatively, skip the module and edit the two defaults in `script.sh.erb`
directly — a system app is site-owned, so hardcoding the site's paths there is
legitimate.

If your site sets `XDG_DATA_HOME` for the module, that works too: the app
resolves the bundle location *before* it redirects the XDG dirs per session, so a
module-provided `XDG_DATA_HOME` is honored.

### 3. Install the app system-wide

```sh
git clone -b dev https://github.com/biopb/biopb-ood.git \
  /var/www/ood/apps/sys/biopb-image-browser
```

It then appears for every portal user under **Interactive Apps**.

### 4. Restrict it to a group (optional)

To limit it to, say, the microscopy group, use OnDemand's application access
control. The exact mechanism is version-specific — check your OnDemand
documentation for *Application Access Control* / app ACLs rather than copying a
snippet, and confirm on the portal host.

### 5. Review the site settings

| setting | where | note |
|---|---|---|
| Node URI | `template/before.sh.erb` builds `/node/$host/$port` | must match your portal's `node_uri`; a mismatch 404s every request rather than failing visibly |
| Data directory root | `form.yml`, `directory: CurrentUser.home` | **widen this for group shares** — as shipped, users can only browse their own home |
| QOS | form field, default `general` | change the default, or clear it to submit with no `--qos` |
| Cluster | derived from `OodAppkit.clusters` | no edit needed |
| Login host | derived from the cluster's `v2.login.host` | no edit needed; only used for the Arrow Flight tunnel |
| Cache size | form field, default 64 GB | this is **per session**, on node-local disk. A few concurrent sessions per node will find your real limit; lower the default if `/tmp` is small |

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

You should see the shell carrying its injected base:

```html
<head><base href="/node/<node>/<control_port>/"><script>window.__BIOPB_BASE__="…";</script>
```

and every asset URL beneath the same prefix. If the `<base href>` is missing, the
web bundle is older than the CLI.

## When it does not work

| symptom | cause |
|---|---|
| Job exits at once, "does not support `--url-prefix`" | biopb predates #731 — rebuild, or use this app's `main` branch |
| Page loads blank, console 404s on `/assets/*` | CLI and bundle are from different trees |
| Portal says 503 / failed to connect | the control did not bind the node's interfaces; check `BIOPB_CONTROL_HOST` in the job output |
| Every request 404s | the portal's `node_uri` is not `/node` |
| Catalog stays empty, `source_count: 0` | missing format extras — see A.1 |
| `401 Unauthorized` | open the Connect button from the card; it carries the token |

Job output lands in the session directory under
`~/ondemand/data/sys/dashboard/batch_connect/`.
