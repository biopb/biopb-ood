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

**[INSTALL.md](INSTALL.md)** has the deployment steps. **[DESIGN-NOTES.md](DESIGN-NOTES.md)**
has the rationale behind specific choices below, if you need it.

## Requirements

- **biopb 0.13.0 or newer**, with a matching CLI and web bundle from the same
  release.
- **Open OnDemand**, with Slurm and a home directory the compute nodes can see.

See [INSTALL.md](INSTALL.md) for single-user and site-wide setup — everything
else (Slurm resources, cluster config, install layout) comes with those two.

## Routing

The web UI is served through OnDemand's own `/node/<host>/<port>/` proxy, so the
session card is a **Connect** button and there is no tunnel to run.

This needs **biopb 0.13.0 or newer**, which added `--url-prefix` support; the
launcher refuses to start without it rather than serving a blank page. Against
older installs, use this app's [`tunnel`](../../tree/tunnel) branch instead —
same app, moved over SSH.

### Security model

The control plane binds the node's public interface (not loopback) so OnDemand's
proxy can reach it, and it has no TLS of its own: the access token that gates
the data and admin API crosses the portal → compute-node hop in the clear. This
is the same posture as the portal's other batch-connect apps (e.g. Jupyter) and
is accepted on that basis. A site that can't accept it should use the
[`tunnel`](../../tree/tunnel) branch instead, which keeps every listener on
loopback.

## Files

| File | Role |
|---|---|
| `INSTALL.md` | how to deploy it, single-user and site-wide |
| `manifest.yml` | app name, category, icon |
| `form.yml.erb` | the launch form (the `.erb` suffix is what gets it rendered) |
| `submit.yml.erb` | Slurm resources + which vars reach `view.html.erb` |
| `template/before.sh.erb` | allocates ports + access token on the compute node |
| `template/script.sh.erb` | writes the session config and runs `biopb control run` |
| `view.html.erb` | the session card: Connect button, token, Flight endpoint or tunnel |

`template/` is the part OnDemand stages into the job directory. Scripts placed
outside it are never staged.

`template/script.sh.erb` must stay **executable** (`100755`); `before.sh.erb`
stays `0644` (sourced, not executed) — see [DESIGN-NOTES.md](DESIGN-NOTES.md)
if you're wondering why that distinction matters.

## Start-up seqeunce

1. `before.sh.erb` refuses to start if you already have a session running (see
   [Isolation](#isolation-and-multi-tenancy)), then allocates ports, an access
   token, and the portal prefix.
2. `script.sh.erb` runs `biopb control run` and waits for HTTP 200 on
   `/data_plane/readyz` — meaning the data plane is genuinely serving, not
   just that the sidecar answered — for up to 15 minutes.
3. The session card shows a Connect button carrying the token.

**Watch the data directory** (on by default) decides whether the session opens
immediately with the catalog filling in behind it, or waits for a full scan of
the data directory first:

| | what the first 200 means |
|---|---|
| **Yes** (default) | the session opens in seconds; images appear as they're found |
| No | nothing answers until the whole directory has been walked; the first 200 carries a complete catalog |

A cold start on a small dataset is ~8 seconds either way.

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
| Page loads blank, console 404s on `/assets/*` | the web bundle predates 0.13.0, or is from a different release than the CLI — the job output warns about this at startup |
| Portal returns 503 / "failed to connect" | the control did not bind the node's interfaces; check `BIOPB_CONTROL_HOST` in the job output |
| Connect button lands on a plain Apache "Not Found" (`Server at … Port 443` in the footer) | the portal never matched the route — see [INSTALL.md](INSTALL.md#5-review-the-site-settings) for node URI / host naming |
| Every request 404s, but the page itself loaded | the prefix biopb was told does not match what the portal sends |
| `401 Unauthorized` | open the button from the card — it carries the token |
| Catalog empty at first | still indexing; it fills in progressively |
| Job exits immediately | `biopb` is missing, too old for `--url-prefix`, or the webapp bundle is absent — the error names which |

Job output lands in the session directory under `~/ondemand/data/sys/dashboard/batch_connect/dev/`.
