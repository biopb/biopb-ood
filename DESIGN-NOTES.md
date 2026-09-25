# Design notes

Internal record of *why* this app is built the way it is — pulled out of
`README.md` on 2026-09-25 to keep that file short and current. Not shown to
portal users, not linked from the app's own UI or form. If something here goes
stale as the code changes, fix it here or delete it — don't let it drift.

## Why `--url-prefix` is needed at all

OnDemand's `/node/<host>/<port>/` route passes the full, untouched path to the
backend and rewrites nothing in the response body, so the app has to know the
sub-URI it is being served under — the same reason Jupyter apps are launched
with `--ServerApp.base_url=…`. biopb learns it from `--url-prefix`, which
`before.sh.erb` derives as `/node/$host/$port` and hands to both the launcher
and the card. The control then strips the prefix off incoming requests and
rewrites the SPA shell (a `<base href>`, the root-absolute asset URLs, and a
`window.__BIOPB_BASE__` the app reads instead of a build-time constant) so
everything resolves back inside the session's namespace.

This needs biopb 0.13.0 or newer (biopb/biopb#731 added `--url-prefix`).
`script.sh.erb` checks for the flag and refuses to start without it, rather than
letting the session come up as a blank page. Against 0.12.0 or earlier, use the
[`tunnel`](../../tree/tunnel) branch instead — same app, moved over SSH.

Do **not** point `node_uri` at `/rnode/`: that route strips the prefix before
the backend sees it, which is the opposite of what `--url-prefix` expects.

## The control-plane plaintext trade (accepted, not an oversight)

OnDemand's proxy runs on the portal's web node and connects to the compute node
over the network, so the control plane binds `0.0.0.0` here instead of loopback.
That is `BIOPB_CONTROL_HOST`, and it is the escape hatch biopb/biopb#618 left
open on purpose: *"publishing the UI stays possible for someone fronting it with
their own TLS proxy, but only as the deliberate, named act of passing a public
`--control-host`."* OnDemand is that proxy — for the browser → portal leg.

It is not one for the portal → compute-node leg. The control has no TLS support
at all (its `uvicorn.Config` sets no `ssl_certfile`/`ssl_keyfile`; biopb's `--tls`
reaches only the Flight plane), so the access token that gates the data *and*
admin API crosses the cluster network in the clear. Note #614 is closed but did
not fix this: #618 resolved it by taking the public bind away, not by adding TLS,
which is exactly why publishing the UI is a deliberate act here.

**This deployment accepts that**, because the portal's Jupyter app is configured
the same way and the compute network is trusted — biopb introduces no exposure
the site does not already carry (decided 2026-08-09). A site that cannot make
that assumption should run the [`tunnel`](../../tree/tunnel) branch instead: it
keeps every listener on loopback and moves the whole session over SSH.

The sidecar is unaffected: it stays on `127.0.0.1` always.

One further consequence of the public bind: biopb gates the session console on
the control's own bind address, so it is *off* in these sessions —
`session console disabled: control bound to 0.0.0.0 (not loopback)` in the job
output. The tunnel branch, whose control stays on loopback, keeps it.

## Why the Flight TLS pairing (`--grpc-bind` + `--tls`) is set together

biopb defaults TLS *on* for a public `--grpc-bind` and off for loopback, so
`template/script.sh.erb` sets the two flags as a pair deliberately — keeping the
exposure and its protection from drifting apart in a later edit. A public bind
also makes the access token mandatory in biopb, which this app has already
supplied.

Neither Flight mode is reachable from off campus; that is site policy, not this
app.

## How the single Flight certificate works from every node (measured, not assumed)

Flight TLS is trust-on-first-use: the certificate is self-signed, there is no
CA, and the client either pins the leaf on first connect (biopb/biopb#604) or is
given its fingerprint up front, which the session card shows. Either way the
anchor is the presented certificate itself, byte for byte.

That fact is what makes a single certificate, minted wherever it happens to be
minted first, correct on every node. gRPC verifies the *dialed* name against the
certificate's SANs, so it would seem to need every node's name listed — but
whenever the anchor is the presented leaf, biopb's client substitutes a name the
certificate *does* list before checking (`_resolve_hostname_override`, in
`biopb.tensor._tls`). That is sound specifically because no other,
validly-issued certificate can satisfy a pin demanding an exact match: hostname
verification exists to catch a MITM presenting a *different* cert, and pinning
the leaf has already ruled that out. Confirmed directly against a live server: a
certificate minted on one node, dialed from another by name, connects with no
manual override, in both TOFU and fingerprint-pinned mode.

So `template/before.sh.erb` mints the certificate with biopb's own default (this
host's names) on whichever node first runs a remote-Flight session, and never
touches it again except on an explicit rotate request. Because biopb's state
directory is NFS home, that is the same file — and the same fingerprint — on
every node afterward, for every relaunch.

The one client mode this does not cover is an explicit `ca_pem` — there, a
*different* validly-issued certificate really could exist, so the SAN check
stays load-bearing and the substitution above does not apply. This app never
asks anyone to use that mode: it recommends the fingerprint, or plain TOFU. (The
HTTP sidecar's own internal Flight client *does* use `ca_pem` — reading the same
cert directly off local disk at its own startup — but always dials loopback,
whose SAN entry is always present, so this exception never bites it.)

The private key is per-user and readable only by you. It must stay that way: the
leaf *is* the trust anchor, so a shared key would let one user impersonate
another's data plane.

If the `tls` extra is missing, no certificate can be minted; the launcher says so
and falls back to loopback for that session rather than failing the launch. The
fallback is in the safe direction, and the card follows what actually happened
rather than what the form asked.

## Why there is no in-place certificate renewal

biopb has no partial-reissue path: `cert init` either reuses the file on disk
as-is, or (`--force`) mints an entirely new 2048-bit RSA keypair and a fresh
self-signed leaf with a new random serial and new dates
(`biopb_tensor_server/core/tls.py`). The fingerprint clients pin on is a SHA-256
of the whole DER-encoded certificate, not just the public key, so even a
hypothetical same-key reissue would still produce a different fingerprint and
break every existing pin. "Renew" and "rotate" are the same operation here —
there is nothing cheaper to design around.

**Never rotated automatically.** `cert init --force` invalidates pins that
clients already hold, and doing that silently at launch is precisely the
surprise this app exists to avoid. Expiry is still enforced at the TLS layer
even under a pin (biopb/biopb#913, confirmed live against pyarrow + gRPC — an
expired self-signed leaf fails the handshake with `certificate verify failed:
certificate has expired`, even for a client that already pinned it), so a lapsed
certificate does need re-minting by hand — and every client then re-pins. See
the **Rotate Arrow Flight certificate** form field and `before.sh.erb`'s
`--checkend` warning, added specifically because this failure mode used to be
silent (biopb-ood#1).

### What happens if the certificate expires while a session is already running

Nothing, at first — TLS validity is only checked at handshake time, not
continuously, and both the HTTP sidecar and any already-connected SDK/napari
client are reusing an already-established connection. The HTTP sidecar in
particular lazily connects once (`_SidecarContext.get_client()`,
`biopb_tensor_server/serving/http_server.py`) and never resets that cached
client on a failed health check — so a running viewer can outlive the cert's
`notAfter` by a long time with no visible symptom, then go dark all at once the
next time anything forces a fresh handshake (a network blip, a relaunch, a new
SDK client connecting). The client-visible error in all these cases is an opaque
`FlightUnavailableError: ... Ssl handshake failed` — the real reason only
appears in gRPC's absl stderr logging (biopb/biopb#1116, filed upstream).

Because rotation in this app always happens inside `before.sh.erb`, which always
completes before `script.sh.erb` starts any process, and because "one server per
user" means rotation can only ever happen as part of a fresh launch (never
against an already-running session), every reader of the cert file — control,
Flight, and the sidecar — is a brand-new process reading the freshly-rotated
bytes at its own startup. There is no stale-in-memory case for the rotation path
itself, only for the earlier expire-while-running case above.

## Why the readiness gate is what it is

Gate on HTTP 200 from `/data_plane/readyz`, and nothing else:

- **Not** the control's `data_plane.state == "serving"`. That comes from a TCP
  probe of the *Flight* port, which comes up about two seconds before the HTTP
  sidecar binds — gate on it and the UI still gets 502s.
- Health probes (`/readyz`, `/livez`, `/healthz`) live at the sidecar **root**;
  only data endpoints are under `/api/*`. `/data_plane/api/readyz` is a 404 by
  design, not a bug.

**0.13.0 changed what that 200 means**, and waiting for one is right either way.
Before it, `/readyz` answered 200 unconditionally — including while its body said
`"status":"degraded"`, `"source_count":0`, with no backend connection at all,
because it only *peeked* for a Flight client instead of making one
(biopb/biopb#755). The gate passed early: on 0.12.0 this app announced a ready
session roughly four minutes before the UI could list a source, and the viewer
sat on "Connecting to server…" in the meantime.

0.13.0 makes `/readyz` connect, answer from that health alone, and return **503
until Flight says `SERVING`** — so a 200 means a data plane that is genuinely
there, rather than a sidecar that merely answered. Since 0.13.0 is this app's
floor, that is the behaviour you get; the paragraph above is only here to explain
what an older install did.

`SERVING` is not a promise of a complete catalog. Under progressive discovery
(biopb/biopb#212) the server reaches `SERVING` immediately and populates behind
you, carrying freshness in `full_scan_in_progress` and
`last_full_scan_finished_at`; a client needing a complete catalog waits on those
fields, not on `SERVING`. Which behaviour you get is decided by "Watch the data
directory" on the launch form — Yes (default) reaches `SERVING` immediately with
the catalog filling in behind it; No walks the whole tree before binding
anything, so the first 200 does carry a complete catalog, at the cost of a
launch that can take minutes on a large tree.

`script.sh.erb` allows 15 minutes and logs a line a minute with the last status.
Timing out is not fatal — a very large tree can outlast the wait, and the
session is usable the moment it finishes. A cold start on a small dataset is ~8
seconds either way.

## Why state moved from per-session to per-user (`2b18dba`)

This reverses an earlier design that gave each session its own copy of biopb's
base dirs. That fought biopb, whose state tree is a singleton by construction:
one `control.pid`, one `control.json`, one credential, one session registry, and
a CLI of `control start` / `stop` / `status`. Keeping state in home also makes
`~/.local` being the same NFS tree on every node work *for* the deployment: the
TLS certificate, the access token and the discovery record become stable across
sessions and across nodes for free. A per-session state tree instead re-mints the
certificate on every launch, which breaks every client's TOFU pin
(biopb/biopb#913).

The guard uses Slurm as its authority, not `control.json`:

| | |
|---|---|
| liveness | `squeue -u $USER -n biopb-browser`, counting `RUNNING`, `CONFIGURING` and `COMPLETING` |
| where to send the user | the node from Slurm, the port from `control.json` — that record's `host` is the *bind* address (`0.0.0.0`), not a routable name |
| simultaneous launches | the lower job id wins; both sides apply the same tie-break to the same list, so exactly one proceeds and no lock file is needed |

Slurm rather than the record, because `control.json` is published on serve and
retracted only on a *clean* stop. A `scancel`, an OOM kill or a node failure
leaves it behind, and a record-based guard would then refuse to start forever
with no way for the user to clear it from the portal. When no sibling job is
running, a leftover record is treated as stale and removed.

The access token persists across sessions for the same reason. It is kept in
`~/.local/state/biopb-ood/token` (mode `600`), owned by this app rather than read
back from biopb's own `~/.local/state/biopb/tensor-server.token` — biopb writes
that file on serve and *removes* it on a clean stop, so reading it back would
hand out a fresh token after every tidy shutdown.

What this gives up is two concurrent sessions with different data directories or
different resource shapes. For an image browser that is a thin use case, and it
buys away the whole class of shared-state problems above.

One consequence worth knowing: because state is no longer per-session, anything
the UI writes through the admin pages (the MCP config) now persists in the
user's home and outlives the session, and the control's log lands in
`~/.local/state/biopb/logs` on NFS home — `biopb control run` hardcodes that path
and exposes no flag for it. Left as is: at `--log-level INFO` with one server per
user the volume is small.

## The executable-bit story

`template/script.sh.erb` must stay **executable** (`100755`). The renderer does
`output_file.chmod(file.stat.mode)`, so the rendered `script.sh` inherits the
`.erb`'s mode, and the job script *executes* it — while `before.sh` is only
sourced, which is why that one can stay `0644`. Committing it 0644 gets you a
job that writes `connection.yml`, hits `Permission denied` on the next line, and
leaves a session card with nothing on it.

## Site-specific settings

This used to live in `README.md` as "Site-specific settings to check." It is now
[INSTALL.md's "Review the site settings"](INSTALL.md#5-review-the-site-settings)
table; kept here only as a pointer so old links don't dead-end silently.

## Testing changes without the portal

`biopb control run` is an ordinary foreground process, so the app can be
exercised from a normal Slurm job by rendering the templates with `erb` and
supplying stand-ins for OnDemand's `find_port` / `port_used` / `create_passwd`
helpers.

One thing a hand-rolled `erb` run will *not* reproduce is the binding, and the
two the dashboard uses are not the same:

| file | binding | form values are |
|---|---|---|
| `submit.yml.erb` | an `OpenStruct` of the form (`SessionContext#to_openstruct`) | bare: `<%= qos %>` |
| `template/*.erb` | `TemplateBinding.new(session, context)` — a two-member Struct, no `method_missing` | qualified: `<%= context.user_data_dir %>` |

A bare form name in a staged template raises `undefined local variable or
method` at submit time, which surfaces as a dashboard backtrace and no job.

The portal hop is the one part that needs no portal to test: OnDemand's `/node/`
route passes the path through unchanged, so requesting the prefix directly
against the compute node is byte-for-byte what the proxy sends.

```sh
curl -s "http://<node>:<control_port>/node/<node>/<control_port>/" | head
```

That must come back with `<base href="/node/<node>/<control_port>/">` and asset
URLs under the same prefix. Note the node name has to be the one your portal's
`host_regex` accepts — the same FQDN `before.sh.erb` puts in the prefix, not the
short name — or you are testing a path the proxy would never send.

Both branches were validated end to end this way, including a PNG render
round-trip; the [`tunnel`](../../tree/tunnel) branch additionally over a real
ProxyJump tunnel.

## Branch history

`main` and `dev` were two deliberately separate variants until 2026-08-17
(commit `3d882d1`, "Merge dev: serve the UI through the OnDemand proxy"): `main`
was the SSH-tunnel deployment, `dev` the OnDemand-proxy one, kept apart because
the proxy variant needed `--url-prefix` (biopb/biopb#731), which was unreleased
at the time. Once biopb 0.13.0 shipped that flag, `main` merged `dev` in
wholesale (every conflict resolved in dev's favor) and became the proxy variant
too; the SSH-tunnel deployment moved to its own `tunnel` branch instead of
staying on `main`. As of 2026-09-25, `main` has not been touched since that
merge — `dev` is ahead by whatever has landed since (one-server-per-user, token
persistence, Flight TLS, and this file's own predecessor cleanups) — and a merge
from `dev` back into `main` is a clean, conflict-free fast-forward-equivalent
whenever someone wants to cut it.
