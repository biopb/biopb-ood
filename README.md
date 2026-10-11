# BioPB — Open OnDemand app

**Agentic bio-image analysis.** An OnDemand Batch Connect app that runs the BioPB
stack on a compute node, so you can work with microscopy data stored on the
cluster from a web browser: analyse it in notebooks or with an AI agent, and
browse and view it.

The session starts `biopb-control run`, which is the entire deployment in one
foreground process:

```
compute node (all listeners on 127.0.0.1)
  control plane   base+3   serves the web UI, proxies everything below
    ├── /                  the React SPA (dashboard, data browser, viewer, /admin)
    ├── /api/*             control API (status, data-plane verbs)
    └── /data_plane/*      reverse proxy ──┐
  HTTP sidecar    base+4   <───────────────┘  data-plane REST + /ws/render
  Arrow Flight    base+5   gRPC data plane — Python/Java SDK, napari
  JupyterLab      base+6   optional — notebooks and a terminal on this node
```

**[INSTALL.md](INSTALL.md)** has the deployment steps. **[DESIGN-NOTES.md](DESIGN-NOTES.md)**
has the rationale behind specific choices below, if you need it.

## Requirements

- **biopb 0.16.0 or newer**, with a matching CLI and web bundle from the same
  release. 0.16 is what lets an agent ask the running session for a kernel
  instead of starting its own, and what makes a data directory that is not
  watched open at once rather than after a full walk. The portal-origin setting
  (INSTALL.md) needs 0.15.2; without it everything else works and the agent
  hands out a path instead of a full link.
- **Open OnDemand**, with Slurm and a home directory the compute nodes can see.

See [INSTALL.md](INSTALL.md) for single-user and site-wide setup — everything
else (Slurm resources, cluster config, install layout) comes with those two.

## Routing

The web UI is served through OnDemand's own `/node/<host>/<port>/` proxy, so the
session card is a **Connect** button and there is no tunnel to run.

This needs `--url-prefix` support (added in biopb 0.13.0; this app as a whole
needs 0.15.0, see [Requirements](#requirements)); the launcher refuses to start
without the flag rather than serving a blank page. Against older installs, use
this app's [`tunnel`](../../tree/tunnel) branch instead — same app, moved over
SSH.

### Security model

The control plane binds the node's public interface (not loopback) so OnDemand's
proxy can reach it, and it has no TLS of its own: the access token that gates
the data and admin API crosses the portal → compute-node hop in the clear. This
is the same posture as the portal's other batch-connect apps (e.g. Jupyter) and
is accepted on that basis. A site that can't accept it should use the
[`tunnel`](../../tree/tunnel) branch instead, which keeps every listener on
loopback.

## JupyterLab and an agent terminal

Optional, off by default (form: **JupyterLab and agent terminal**). With it on,
the job also starts JupyterLab at `/node/<host>/<base+6>/`, and the card gets
an **Open JupyterLab** button.

- **Notebooks** — pick the kernel *biopb: connect to the running biopb session*.
  It runs in the session's namespace (`client`, `ops`), so it shares its kernel
  with everything else attached. **No session is started with the job**: one
  exists once an agent has attached or you have started one from the dashboard,
  and until then a notebook says "no running biopb session". With several, the
  notebook takes the newest. There is no napari window on a compute node;
  look at results in the web viewer. The agent gives you the viewer link for the
  portal, not the node's loopback one, when the site has set the portal's origin
  (`BIOPB_PUBLIC_ORIGIN`, see [INSTALL.md](INSTALL.md#5-review-the-site-settings));
  without it you get the path and open it on the portal you are already on.
- **A terminal** is a shell on the node, for an AI agent you have installed. The
  agent's stdio shim finds this job's control (`$BIOPB_CONTROL_PORT`) and, when
  the agent attaches, takes a free session or asks it to launch one, as the agent
  chooses. That is what creates the session the notebook then shares. With a site's JupyterLab module loaded, the terminal gets the job's own `PYTHONPATH`, not
  the module's, which would break biopb's tools there.
- **Finding JupyterLab** is the site's business, not this app's: see
  [INSTALL.md](INSTALL.md#4-jupyterlab-and-terminal-optional).

### Security

- JupyterLab has its own token, new every session, in the link the card gives
  you. A Lab terminal is a shell as you. Like the biopb token, it crosses the
  portal → node hop in the clear.
- The session's `/mcp` endpoint is on loopback with **no token of its own**, so on
  a node shared with other users' jobs, any of them can run code as you through
  it. The kernel itself is safe (its connection file is `0600`, in a private
  directory on node-local disk). **Exclusive node** removes the exposure by
  giving the job the whole node; leave it off only where two users never share
  one. This is biopb's to fix properly (a token on the session endpoint).
- The session and the agent see everything your account can.

## Files

| File | Role |
|---|---|
| `INSTALL.md` | how to deploy it, single-user and site-wide |
| `manifest.yml` | app name, category, icon |
| `form.yml.erb` | the launch form (the `.erb` suffix is what gets it rendered) |
| `submit.yml.erb` | Slurm resources + which vars reach `view.html.erb` |
| `template/before.sh.erb` | one-session-per-user guard; allocates ports + access token, mints the Flight certificate, finds JupyterLab |
| `template/script.sh.erb` | writes the session config, runs `biopb-control run`, and (optionally) starts the session and JupyterLab |
| `template/after.sh.erb` | holds the session card back until the control is listening, so its buttons work when it appears |
| `template/terminal-shell.sh` | the shell a JupyterLab terminal runs, to give it the job's own `PYTHONPATH` back when Lab came from a module |
| `view.html.erb` | the session card: the Connect, JupyterLab and shell buttons, token, Flight endpoint or tunnel |

`template/` is the part OnDemand stages into the job directory. Scripts placed
outside it are never staged.

`template/script.sh.erb` must stay **executable** (`100755`); `before.sh.erb`
stays `0644` (sourced, not executed) — see [DESIGN-NOTES.md](DESIGN-NOTES.md)
if you're wondering why that distinction matters.

## Start-up sequence

1. `before.sh.erb` refuses to start if you already have a session running (see
   [Isolation](#isolation-and-multi-tenancy)), then allocates ports, an access
   token, and the portal prefix.
2. `script.sh.erb` runs `biopb-control run` and waits for HTTP 200 on
   `/data_plane/readyz` — meaning the data plane is genuinely serving, not
   just that the sidecar answered — for up to 15 minutes.
3. With JupyterLab on, `script.sh.erb` then starts JupyterLab. It does not start
   a biopb session: that waits for an agent or the dashboard to ask for one (see
   [DESIGN-NOTES.md](DESIGN-NOTES.md)).
4. The session card shows a Connect button (to the BioPB dashboard) carrying the
   token, an Open JupyterLab button when JupyterLab is on, and an Open Shell
   button. The card goes live once the control is listening; JupyterLab can take
   a little longer.

The session opens within seconds and the catalog fills in behind it, whatever the
data sources are.

## Data sources and cache: your `biopb.json`

The launch form does not ask for a data directory, cache size or watch setting.
The session serves `~/.config/biopb/biopb.json` (`$BIOPB_CONFIG_HOME/biopb.json`
if you set it), the file biopb reads by default, and the **admin page** in the
dashboard edits that same file. Add sources there, then use **Restart** (or
**Start**) to apply. What you save persists across launches. If the file does not
exist, the first launch writes an empty one.

Per source, `monitor` decides what happens after the first scan:

| | what happens to the directory |
|---|---|
| `false` (default) | walked once, in the background; files added later are not picked up |
| `true` | walked again on every pass to find files added or removed; every pass checks every file, so use it for a directory of modest size, not a whole archive |

The ports and bind address are set by the launcher, not by the file: a
`server.host` or `server.port` saved in the admin page is ignored, so the
session card's address stays correct. The disk cache defaults to
`${TMPDIR:-/tmp}/biopb-cache-<uid>` on the node's local disk; set
`cache.file_cache_dir` and `cache.file_max_total_gb` in the file to change it.

## Isolation and multi-tenancy

One BioPB session per user, enforced against Slurm rather than a session-record
file (so a `scancel` or crash can't wedge the guard open). biopb's own state
(`~/.config/biopb`, `~/.local/state/biopb`, `~/.local/share/biopb`) is left
where biopb puts it, not redirected per session, since it's a singleton by
construction — this is also what keeps the access token and TLS certificate
stable across relaunches and nodes.

Several *users* can still share a compute node: ports are per-session, and the
access token is what keeps one user's data out of another's reach on the ports
every user on the node can otherwise reach (the control port, plus the
sidecar and Flight ports even though those are loopback-bound).

The token persists across relaunches in `~/.local/state/biopb-ood/token`
(mode `600`); rotate it by deleting that file.

So does the catalog's persistent part (ROIs you draw, decode-rate measurements):
biopb names it after the config file's path, which is the same every launch, so
the same file under `~/.local/state/biopb/catalogs/` is reopened each time. It is
in your home, not on the node's local disk, so it follows you to whichever node
the next launch lands on. Delete it to start clean. (The list of sources is
rebuilt on every start.) A catalog from an earlier version of this app, at
`~/.local/state/biopb-ood/catalog.duckdb`, is no longer read.

## Remote Arrow Flight

The **Arrow Flight access** form field controls whether the gRPC data plane
(the Python/Java SDK, napari) is reachable from your own machine. Defaults to
remote; the web UI is unaffected either way.

| | Remote (default) | Loopback only |
|---|---|---|
| `--grpc-bind` | `0.0.0.0` | `127.0.0.1` |
| TLS | `--tls` | `--no-tls` |
| Client dials | `grpcs://<node>:<port>` directly | `grpc://localhost:<port>` through `ssh -L` |

Neither mode is reachable from off campus; that's site policy, not this app.

### The certificate

Flight TLS is trust-on-first-use: self-signed, no CA, pinned on first connect —
or verified against the fingerprint the session card shows. It's per-account
(not per-session), minted once and reused on every node without listing every
node's name in it.

Certificates are **never rotated automatically** — that would invalidate every
client's existing pin. If a session warns that the certificate is expiring
soon, relaunch with **Rotate Arrow Flight certificate** set to Yes. There is no
in-place renewal in biopb — this mints a brand-new certificate, and every
pinned client (a saved `tls_fingerprint`, not plain TOFU) must re-pin from the
new fingerprint afterward.

If the `tls` extra isn't installed, remote Flight falls back to loopback for
that session rather than failing the launch.

### Data access from Python, Java or napari

Arrow Flight is never published through the portal — the OnDemand proxy is HTTP
and can't carry gRPC. With **remote** Flight it's published on the compute node
directly instead; the card gives you the endpoint and certificate fingerprint:

```python
from biopb.tensor import TensorFlightClient
client = TensorFlightClient(
    "grpcs://<node>:<grpc_port>",
    token="<token>",
    tls_fingerprint="<fingerprint from the session card>",   # optional; verifies the first connect
)
arr = client.get_tensor("<source_id>/<field>")   # lazy dask array
```

Omit `tls_fingerprint` to pin on first use instead (stored in
`~/.local/state/biopb/tls-known-hosts.json`, keyed by `host:port` — since the
port changes every launch, each session is a fresh first-connect, which is why
checking the fingerprint is worth doing rather than letting it pin silently).

Don't pass `tls_ca_pem` as well as `tls_fingerprint` — the former silently wins
and a wrong fingerprint would be accepted without error.

With **loopback only**, run the `ssh -L` command from the card and dial
`grpc://localhost:<grpc_port>` with no TLS argument.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No form at all: "This app requires clusters that do not exist or you do not have access to" | the form file is not named `form.yml.erb`, so its ERB never ran and `cluster` is a literal `<%- … -%>` string. Otherwise: the cluster really is absent from `/etc/ood/config/clusters.d`, or your account is not allowed to submit to it |
| Page loads blank, console 404s on `/assets/*` | the web bundle is from a different release than the CLI (or predates 0.13.0) — the job output warns about this at startup |
| Portal returns 503 / "failed to connect" | the control did not bind the node's interfaces; check `BIOPB_CONTROL_HOST` in the job output |
| Connect button lands on a plain Apache "Not Found" (`Server at … Port 443` in the footer) | the portal never matched the route — see [INSTALL.md](INSTALL.md#5-review-the-site-settings) for node URI / host naming |
| Every request 404s, but the page itself loaded | the prefix biopb was told does not match what the portal sends |
| `401 Unauthorized` | open the button from the card — it carries the token |
| Catalog empty at first | still indexing; it fills in progressively |
| Job exits immediately | `biopb` is missing, too old for `--url-prefix`, or the webapp bundle is absent — the error names which |

Job output lands in the session directory under `~/ondemand/data/sys/dashboard/batch_connect/dev/`.
