# BioPB Image Browser — Open OnDemand app

An OnDemand Batch Connect app that runs the full BioPB stack on a compute node so
you can browse microscopy data stored on the cluster from a web browser.

The session starts `biopb control run`, which is the entire deployment in one
foreground process:

```
compute node (all listeners on 127.0.0.1)
  control plane   base+3   serves the web UI, proxies everything below
    ├── /                  the React SPA (dashboard, /viewer, /admin)
    ├── /api/*             control API (status, data-plane verbs)
    └── /data_plane/*      reverse proxy ──┐
  HTTP sidecar    base+4   <───────────────┘  data-plane REST + /ws/render
  Arrow Flight    base+5   gRPC data plane — Python/Java SDK, napari
```

Images are transcoded to Arrow on demand, at chunk granularity, into a
multi-resolution pyramid — so whole-slide and larger-than-memory datasets open
without any staging or import step, and files stay in their original format.

## How the UI reaches your browser

The web UI is served through OnDemand's own `/node/<host>/<port>/` proxy, so the
session card is a **Connect** button and there is no tunnel to run.

That route passes the full, untouched path to the backend and rewrites nothing in
the response body, so the app has to know the sub-URI it is being served under —
the same reason Jupyter apps are launched with `--ServerApp.base_url=…`. biopb
learns it from `--url-prefix`, which `before.sh.erb` derives as
`/node/$host/$port` and hands to both the launcher and the card. The control then
strips the prefix off incoming requests and rewrites the SPA shell (a
`<base href>`, the root-absolute asset URLs, and a `window.__BIOPB_BASE__` the
app reads instead of a build-time constant) so everything resolves back inside
the session's namespace.

This needs **biopb/biopb#731**, which is on biopb's `dev` branch and not in a
release. `script.sh.erb` checks for `--url-prefix` and refuses to start without
it, rather than letting the session come up as a blank page. The `main` branch of
this app is the tunnel variant and works against the 0.12.0 release.

### What this costs, and why the tunnel branch still exists

OnDemand's proxy runs on the portal's web node and connects to the compute node
over the network, so the control plane binds `0.0.0.0` here instead of loopback.
That is `BIOPB_CONTROL_HOST`, and it is the escape hatch biopb/biopb#618 left
open on purpose: *"publishing the UI stays possible for someone fronting it with
their own TLS proxy, but only as the deliberate, named act of passing a public
`--control-host`."* OnDemand is that proxy — for the browser → portal leg.

It is not one for the portal → compute-node leg. The control has no TLS support
at all (its `uvicorn.Config` sets no `ssl_certfile`/`ssl_keyfile`; biopb's `--tls`
reaches only the Flight plane), so **the access token that gates the data *and*
admin API crosses the cluster network in the clear.** Note #614 is closed but did
not fix this: #618 resolved it by taking the public bind away, not by adding TLS,
which is exactly why publishing the UI is a deliberate act here.

**This deployment accepts that**, because the portal's Jupyter app is configured
the same way and the compute network is trusted — biopb introduces no exposure
the site does not already carry. A site that cannot make that assumption should
run the `main` branch instead: it keeps every listener on loopback and moves the
whole session over SSH.

The sidecar and the Arrow Flight plane are unaffected: they stay on `127.0.0.1`.
Flight is therefore still tunnel-only, which is what the session card shows for
SDK and napari users.

One further consequence of the public bind: biopb gates the **session console**
on the control's own bind address, so it is *off* in these sessions —
`session console disabled: control bound to 0.0.0.0 (not loopback)` in the job
output. The tunnel branch, whose control stays on loopback, keeps it.

## Requirements

**[INSTALL.md](INSTALL.md) is the step-by-step guide**, single-user and
site-wide taken separately. In short:

- A biopb carrying **biopb/biopb#731**, which is on biopb's `dev` branch and
  **not in any release** — so this branch has to be built from source. Both
  halves, the CLI and the web bundle, must come from the same tree: a new CLI
  with an old bundle starts cleanly and then serves a blank page.
- The container image (`jiyuuchc/biopb-tensor-server`) cannot serve this UI. It
  is a headless Flight-only data plane with no web front end.
- Slurm, and a home directory the compute nodes can see.

`script.sh.erb` checks for `--url-prefix` before launching and checks the served
document for its `<base href>` afterwards, so either half being wrong is reported
in the job output rather than guessed at.

`BIOPB_BIN_DIR` and `BIOPB_WEBAPP_DIR` point the app at a build tree; unset, they
default to the installer's locations under `~/.local` and the app behaves
normally.

## Files

| File | Role |
|---|---|
| `INSTALL.md` | how to deploy it, single-user and site-wide |
| `manifest.yml` | app name, category, icon |
| `form.yml` | the launch form (ERB-rendered) |
| `submit.yml.erb` | Slurm resources + which vars reach `view.html.erb` |
| `template/before.sh.erb` | allocates ports + access token on the compute node |
| `template/script.sh.erb` | writes the session config and runs `biopb control run` |
| `view.html.erb` | the session card: Connect button + the Flight tunnel |

`template/` is the part OnDemand stages into the job directory. Scripts placed
outside it are never staged — that was one of the reasons the earlier version of
this app never launched.

## Site-specific settings to check

Four values are site-dependent. The first two can actually break the app.

- **Node URI** — `before.sh.erb` builds the prefix as `/node/$host/$port`, which
  is OnDemand's default `node_uri`. If your portal sets a different one in
  `ood_portal.yml`, change it there — biopb is told this exact string, so a
  mismatch makes every request 404 rather than fail visibly. Do **not** point it
  at `/rnode/`: that route strips the prefix before the backend sees it, which is
  the opposite of what `--url-prefix` expects.
- **Cluster** — `form.yml` builds the list from `OodAppkit.clusters`, so it adapts
  to whatever is in `/etc/ood/config/clusters.d`. If you would rather pin it,
  drop `cluster` from the `form:` list and add a top-level `cluster: "<id>"`.
- **QOS** — a form field, defaulting to `general`. Blank submits with no `--qos`
  at all, so a site that does not use QOS needs no edit. It is a free-text field
  rather than a menu because the valid set is per-account, not per-site; a site
  that wants a menu can swap it for a `select` in `form.yml`.
- **Login host** — read from your cluster's own OnDemand config (`v2.login.host`
  in `/etc/ood/config/clusters.d/<id>.yml`), so there is nothing site-specific to
  edit. It only affects the Arrow Flight tunnel command on the card, and stays
  editable per session. If the lookup finds nothing the field is blank and the
  card shows a direct `ssh` to the compute node instead of a broken `-J`.
  Multi-cluster sites: `form.yml` renders once, so the default takes the first
  job-allowed cluster and cannot follow the cluster menu; drive it from
  OnDemand's `data-set-*` option attributes if that matters.

## How a session works

1. `before.sh.erb` finds a base port whose `+3/+4/+5` offsets are all free,
   generates a 32-character access token, and derives the portal prefix
   `/node/$host/$port`.
2. `script.sh.erb` writes a per-session `biopb.json`, points the transcode cache
   at node-local `/tmp` (not NFS home — it is write-heavy, disposable, and the
   file backend takes a cross-process lock), gives the session its own XDG tree
   (below), and runs `biopb control run` with `--url-prefix` and a `0.0.0.0`
   control bind.
3. It waits for **HTTP 200 on `/data_plane/readyz`**, then confirms the document
   served at the prefix actually carries a `<base href>` — a CLI new enough to
   accept the flag paired with an older web bundle would otherwise come up blank.
4. The session card shows a Connect button pointing at the prefix, carrying the
   token as a query parameter.

### About the readiness gate

Gate on HTTP 200 from `/data_plane/readyz`, and nothing else:

- **Not** the control's `data_plane.state == "serving"`. That comes from a TCP
  probe of the *Flight* port, which comes up about two seconds before the HTTP
  sidecar binds — gate on it and the UI still gets 502s.
- **Not** the response body's `"ready": true`. The sidecar starts answering
  before it has connected to Flight, so a perfectly healthy start reports
  `"status":"degraded"`, `"source_count":0` for a moment.
- Note the path: health probes (`/readyz`, `/livez`, `/healthz`) live at the
  sidecar **root**; only data endpoints are under `/api/*`. `/data_plane/api/readyz`
  is a 404 by design, not a bug.

A cold start on a small dataset is ~8 seconds. Indexing a large tree keeps going
in the background; the UI shows "Indexing…" and fills in as it scans.

## Isolation and multi-tenancy

Ports are allocated per session, so several sessions can share a compute node.
The access token is what keeps one session's data out of another's reach: the
control port is open on the node's interfaces, and the sidecar and Flight ports
— though loopback-only — are reachable by every other user logged in to the same
node.

Each session also gets its own copy of every directory biopb resolves at run
time. biopb honours exactly three XDG base dirs (`biopb/_locations.py`), and all
three are redirected into the staged job directory:

| | holds | why per-session |
|---|---|---|
| `XDG_STATE_HOME` | logs, pid, credential, session registry, the control's discovery record | two sessions would otherwise overwrite each other's credential and fight over one log |
| `XDG_CONFIG_HOME` | `biopb.json`, `mcp-config.json` | a stale `~/.config/biopb` — a legacy `biopb.toml`, say — can no longer change how a session behaves |
| `XDG_DATA_HOME` | webapp / samples lookups | a user's leftover `~/.local/share/biopb/webapp` cannot shadow the bundle the site chose |

`XDG_CACHE_HOME` is redirected too, to node-local disk. biopb does not read it;
the scientific stack underneath does, and those caches otherwise land in NFS home
and get written by every concurrent session on the cluster at once.

The install locations are resolved *before* these take effect, so a site that
ships biopb as a module — setting `XDG_DATA_HOME` itself — still gets its own
bundle. What the overrides neutralize is biopb's implicit fallbacks; every path
this app depends on is passed explicitly (`--config`, `--static-dir`).

Two consequences worth knowing. Anything the UI writes through the admin pages
(the MCP config) lands in the session directory and goes away with the session —
it is not persistent user configuration. And the session ignores whatever biopb
config the user keeps in their home; the data directory comes from the launch
form and nowhere else.

## Using the data from Python, Java or napari

Arrow Flight is not published through the portal, so it needs the tunnel the
session card shows:

```python
from biopb.tensor import TensorFlightClient
client = TensorFlightClient("grpc://localhost:<grpc_port>", token="<token>")
arr = client.get_tensor("<source_id>/<field>")   # lazy dask array
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Page loads blank, console 404s on `/assets/*` | the web bundle predates biopb/biopb#731 — the job output warns about this at startup |
| Portal returns 503 / "failed to connect" | the control did not bind the node's interfaces; check `BIOPB_CONTROL_HOST` in the job output |
| Every request 404s | the portal's `node_uri` is not `/node` — see Site-specific settings |
| `401 Unauthorized` | open the button from the card — it carries the token |
| Catalog empty at first | still indexing; it fills in progressively |
| Job exits immediately | `biopb` is missing, too old for `--url-prefix`, or the webapp bundle is absent — the error names which |

Job output lands in the session directory under `~/ondemand/data/sys/dashboard/batch_connect/dev/`.

## Testing changes without the portal

`biopb control run` is an ordinary foreground process, so the app can be
exercised from a normal Slurm job by rendering the templates with `erb` and
supplying stand-ins for OnDemand's `find_port` / `port_used` / `create_passwd`
helpers.

The portal hop is the one part that needs no portal to test: OnDemand's `/node/`
route passes the path through unchanged, so requesting the prefix directly
against the compute node is byte-for-byte what the proxy sends.

```sh
curl -s "http://<node>:<control_port>/node/<node>/<control_port>/" | head
```

That must come back with `<base href="/node/<node>/<control_port>/">` and asset
URLs under the same prefix. The `main` branch was validated end to end this way
— including the real ProxyJump tunnel and a PNG render round-trip.
