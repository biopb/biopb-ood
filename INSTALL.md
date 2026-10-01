# Installing BioPB for Open OnDemand

- **[Single user](#a-single-user)** — a sandbox app in your own home, visible only
  to you.
- **[Site-wide or group](#b-site-wide-or-group)** — a system app, one shared biopb
  install, visible to everyone or to one group.

## Requirements

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

**RUN ON A JOB NODE, NOT ON A SUBMISSION NODE**

```sh
curl -sSfL https://biopb.org/install.sh | bash
```

This is what biopb documents for its users. It fetches the current release
bundle and sets up `~/.local` — CLI, control plane, tensor server, and the web
bundle.

#### Verify

```sh
biopb-control run --help | grep -- --url-prefix
ls ~/.local/share/biopb/webapp/index.html
```

### 2. Install the ood app

```sh
git clone https://github.com/biopb/biopb-ood.git \
  ~/ondemand/dev/biopb-ood
```

### 3. Launch

In the portal: **Develop → My Sandbox Apps (Development)**, then *BioPB*. Pick a
data directory and submit.

The session card shows a **Connect** button (to the BioPB dashboard). If it does not come
ready, read the job output: every failure this app can anticipate is named there
rather than left as a blank page.

### 4. JupyterLab and terminal (optional)

Set **JupyterLab and agent terminal** to Yes on the launch form. The app does not
install JupyterLab; it looks for one on the compute node, in this order:

1. `BIOPB_OOD_JUPYTER` — the path to a `jupyter-lab` executable.
2. The user's own: `jupyter-lab` on `PATH`, then `~/.local/bin`.
3. The environment module named in the form's *JupyterLab module* field,
   prefilled from `BIOPB_OOD_JUPYTER_MODULE` in the portal's environment.

Most portals already have one for their own Jupyter app, and that is the one to
use. Failing that, a separate tool environment is enough — do not add it to
biopb's:

```sh
uv tool install jupyterlab
```

See [README.md](README.md#jupyterlab-and-an-agent-terminal) for what it starts.

---

## B. Site-wide or group

Everything above applies, plus the following. **Read
[the security note in the README](README.md#what-this-costs-and-why-the-tunnel-branch-still-exists)
before deploying this widely** — it publishes the control plane on the compute
node, and the access token crosses the portal → node hop in cleartext.

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
JupyterLab for the optional JupyterLab feature. Set the module (in the
portal's environment, where it prefills the form; a user can still change it),
and the path if the module does not put `jupyter-lab` on `PATH`. The module is loaded
around the Lab process only, so its `PYTHONPATH` never reaches biopb.
**`BIOPB_OOD_JUPYTER_ORIGIN_PAT`** is for a portal whose proxy does not preserve
the `Host` header: Lab then loads but its kernels and terminals fail with a
403, and a regular expression for the portal's origin (e.g.
`https://portal.example.edu`) is passed as `allow_origin_pat`.

### 3. Install the app system-wide

```sh
git clone https://github.com/biopb/biopb-ood.git \
  /var/www/ood/apps/sys/biopb-ood
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
| JupyterLab | form field, default off | needs a JupyterLab the app can find; see [A.4](#4-jupyterlab-and-terminal-optional). Uses the port after Flight (`base+6`), so a firewall that only opens the first three needs that one too |
| Exclusive node | form field, default off | adds `--exclusive` when JupyterLab is on. **Read the security note in the README before turning JupyterLab on for a shared-node cluster** |
| Cache size | form field, default 64 GB | **per session**, on node-local disk. A few concurrent sessions per node will find your real limit; lower it if `/tmp` is small |
| Cache location | `${TMPDIR:-/tmp}/biopb-ood-<jobid>/cache`, in `template/script.sh.erb` | the job's own directory on the compute node's **local disk**, deleted when the job ends. It is written constantly, so it should not be on NFS or RAM: if `TMPDIR` (or `/tmp`) is `tmpfs`, a network filesystem, or has less free space than the cache size, the job output warns. Point `TMPDIR` at local scratch in the job environment if `/tmp` is a poor fit. Not `$SLURM_TMPDIR` or `$LOCAL_SCRATCH`, which this app does not read |

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
