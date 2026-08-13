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

## Why an SSH tunnel and not the OnDemand proxy

The web UI is **not** served through OnDemand's `/node/<host>/<port>/` proxy. Two
independent reasons:

1. **The SPA is built with `base: "/"`.** It requests `/assets/*`, `/api/*`,
   `/data_plane/*` and the `/data_plane/ws/render` websocket as absolute,
   root-anchored URLs. This is deliberate upstream: *"There is no build-time
   namespacing — the app is always built with base `/`"* (`web/README.md`).
   Neither OnDemand route can absorb that, and neither rewrites response bodies:
   `/node/<host>/<port>/` passes the **full, untouched** path to the backend, so
   the app would have to know its own sub-URI (this is why Jupyter apps are
   launched with `--ServerApp.base_url=…`); `/rnode/` strips the prefix, which
   fixes what the *backend* sees but not what the *browser* resolves — the page
   still lives under `/rnode/<host>/<port>/`, so every root-anchored URL lands at
   the portal root and 404s.
2. **The control plane is plaintext HTTP with no TLS support.** Publishing it
   would put the data-plane access token on the wire in the clear, which is
   exactly what biopb/biopb#614 closed off. It binds loopback and expects to be
   reached over `ssh -L`.

So the session card gives you a tunnel command instead of a link into the portal.

**There is now a proxied alternative, on the [`dev`](../../tree/dev) branch.**
biopb/biopb#731 added `--url-prefix`: the control strips a configured path prefix
off incoming requests and rewrites the SPA shell (a `<base href>`, the
root-absolute asset URLs, and a `window.__BIOPB_BASE__` the app reads in place of
a build-time constant), which is exactly what reason 1 above was missing. That
branch serves the UI through OnDemand's proxy and its session card is a Connect
button.

Two reasons this branch is still the default. #731 is on biopb's `dev` branch and
**not in any release**, so `dev` needs a build from source. And it does not
address reason 2: OnDemand's proxy dials the compute node over the network, so
that branch has to publish the control, and the token then crosses the portal →
node hop in the clear. Use `dev` if your compute network is one you trust —
that is the same bet an OnDemand Jupyter app already makes — and this branch
otherwise.

## Requirements

The full stack must be installed in your home directory — the container image
(`jiyuuchc/biopb-tensor-server`) is a **headless Flight-only data plane** and
carries no web front end, so it cannot serve this UI.

```sh
curl -fsSL https://biopb.org/install.sh | bash
```

That must provide all of:

| Path | What |
|---|---|
| `~/.local/bin/biopb` | CLI with a `control` subcommand |
| `~/.local/share/biopb/webapp/index.html` | the built SPA the control serves |

Verify with `biopb control --help`. A `biopb` older than the one that introduced
`biopb-control` will not work — `script.sh.erb` fails with a clear message if
either piece is missing.

Home is shared with the compute nodes, so one install covers every session.

## Files

| File | Role |
|---|---|
| `manifest.yml` | app name, category, icon |
| `form.yml.erb` | the launch form (the `.erb` suffix is what gets it rendered) |
| `submit.yml.erb` | Slurm resources + which vars reach `view.html.erb` |
| `template/before.sh.erb` | allocates ports + access token on the compute node |
| `template/script.sh.erb` | writes the session config and runs `biopb control run` |
| `view.html.erb` | the session card: tunnel command + link |

`template/` is the part OnDemand stages into the job directory. Scripts placed
outside it are never staged — that was one of the reasons the earlier version of
this app never launched.

`template/script.sh.erb` must stay **executable** (`100755`). The renderer does
`output_file.chmod(file.stat.mode)`, so the rendered `script.sh` inherits the
`.erb`'s mode, and the job script *executes* it — while `before.sh` is only
sourced, which is why that one can stay `0644`. Committing it 0644 gets you a
job that writes `connection.yml`, hits `Permission denied` on the next line, and
leaves a session card with nothing on it.

## Site-specific settings to check

Three values are site-dependent. The cluster is the only one that can break the
app outright; a QOS default your account cannot use just gets the first launch
rejected by Slurm until it is corrected or cleared.

- **Cluster** — `form.yml.erb` builds the list from `OodAppkit.clusters`, so it
  adapts to whatever is in `/etc/ood/config/clusters.d`. If you would rather pin
  it, drop `cluster` from the `form:` list and add a top-level `cluster: "<id>"`.
  Keep the file's `.erb` extension whatever you do: the dashboard renders the
  form through ERB only when the name says `.erb`, and a plain `form.yml` makes
  the app open as *"This app requires clusters that do not exist or you do not
  have access to"* — the ERB tags reach the YAML parser verbatim.
- **QOS** — a form field, defaulting to `general`. Blank submits with no `--qos`
  at all, so a site that does not use QOS needs no edit. It is a free-text field
  rather than a menu because the valid set is per-account, not per-site; a site
  that wants a menu can swap it for a `select` in `form.yml.erb`.
- **Login host** — the form defaults to `mantis-submit.cam.uchc.edu`, the
  round-robin alias for the submit nodes. It only affects the displayed tunnel
  command; users can edit it per session.

## How a session works

1. `before.sh.erb` finds a base port whose `+3/+4/+5` offsets are all free and
   generates a 32-character access token.
2. `script.sh.erb` writes a per-session `biopb.json`, points the transcode cache
   at node-local `/tmp` (not NFS home — it is write-heavy, disposable, and the
   file backend takes a cross-process lock), sets a per-session `XDG_STATE_HOME`
   so concurrent sessions do not collide, and runs `biopb control run`.
3. It waits for **HTTP 200 on `/data_plane/readyz`** before reporting ready.
4. The session card shows the tunnel command and a link carrying the token.

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

## Ports and multi-tenancy

Ports are allocated per session, so several sessions can share a compute node.
Each also gets its own state directory and its own cache directory. The access
token matters even on a loopback bind: compute nodes are shared, and without one
any other user on the node could reach the data API over `127.0.0.1`.

## Using the data from Python, Java or napari

The Arrow Flight port is tunnelable too — add a second `-L` (the session card
shows the exact flag):

```python
from biopb.tensor import TensorFlightClient
client = TensorFlightClient("grpc://localhost:<grpc_port>", token="<token>")
arr = client.get_tensor("<source_id>/<field>")   # lazy dask array
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| No form at all: "This app requires clusters that do not exist or you do not have access to" | the form file is not named `form.yml.erb`, so its ERB never ran and `cluster` is a literal `<%- … -%>` string. Otherwise: the cluster really is absent from `/etc/ood/config/clusters.d`, or your account is not allowed to submit to it |
| `connection refused` in the browser | the `ssh -N -L …` tunnel is not running |
| Card shows but page is blank | check the job output for the control-plane log |
| `401 Unauthorized` | open the link from the card — it carries the token |
| Catalog empty at first | still indexing; it fills in progressively |
| Job exits immediately | `biopb` or the webapp bundle is missing — see Requirements |

Job output lands in the session directory under `~/ondemand/data/sys/dashboard/batch_connect/dev/`.

## Testing changes without the portal

`biopb control run` is an ordinary foreground process, so the app can be
exercised from a normal Slurm job by rendering the templates with `erb` and
supplying stand-ins for OnDemand's `find_port` / `port_used` / `create_passwd`
helpers. That is how this app was validated end to end — including the real
ProxyJump tunnel and a PNG render round-trip.

One thing a hand-rolled `erb` run will *not* reproduce is the binding, and the
two the dashboard uses are not the same:

| file | binding | form values are |
|---|---|---|
| `submit.yml.erb` | an `OpenStruct` of the form (`SessionContext#to_openstruct`) | bare: `<%= qos %>` |
| `template/*.erb` | `TemplateBinding.new(session, context)` — a two-member Struct, no `method_missing` | qualified: `<%= context.user_data_dir %>` |

A bare form name in a staged template raises `undefined local variable or
method` at submit time, which surfaces as a dashboard backtrace and no job.
