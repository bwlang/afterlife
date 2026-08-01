# afterlife

A self-hosted dead-man's switch. You write messages to the people you care
about; the app holds them encrypted and asks you, on a schedule you choose,
whether you're still here. Keep checking in and nothing happens. Stop
checking in — through a grace period, past every reminder — and it delivers
them.

Personal/family scale, not a SaaS. No billing, no tiers.

- [docs/DESIGN.md](docs/DESIGN.md) — what it does and why, including the
  failure modes that drove the design.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — diagrams of the system as
  built: components, the state machine, the check-in and delivery flows.

## The thing to understand first

This app has to work correctly *after* the person maintaining it can no
longer intervene. That inverts the usual reliability priorities. The
dangerous failure isn't a crash — it's silence: a switch that quietly
stopped running months ago and delivers nothing when it finally matters.

Two consequences run through everything here:

- **Something outside this app must watch it.** An external uptime monitor
  polls `GET /health`, which reports the age of the last completed sweep

- **`CLOAK_KEY` and the database are equally required, and independently
  losable.** Message bodies and attachments are encrypted at rest. The
  database without the key is unrecoverable ciphertext.

## How a switch works

```
active ──(missed check-in by next_due_at)──▶ grace
active ──(any check-in)──▶ active (timer reset)
grace  ──(any check-in)──▶ active (timer reset)
grace  ──(grace_period_days elapses)──▶ triggered ──▶ messages delivered
any    ──(pause)──▶ paused ──(resume)──▶ active
```

You can check in three ways: the dashboard button, a one-time link in a
reminder email, or an HTTP request to a per-switch API token
(`/api/check_in/:token`) so a cron job or presence monitor can do it for
you. All three do the same thing — reset the timer to `active` — and each
is recorded in the switch's audit log.

An Oban cron sweep runs every 15 minutes: it sends due reminders, advances
any switch whose deadline has passed, and — when one triggers — enqueues
delivery jobs in the same transaction as the status change, so a switch can
never end up marked triggered with only some of its recipients scheduled.

## Development

We use [pixi](https://pixi.sh) (Elixir 1.20, Erlang 29) for local depenencies

```sh
pixi install
pixi run setup      # hex, rebar, git hooks
mix setup           # deps, database, assets
mix phx.server      # http://localhost:4000
```

Emails in dev go to a local mailbox at `/dev/mailbox` rather than being
sent. `/dev/dashboard` has LiveDashboard.

Before committing:

```sh
mix precommit       # compile --warnings-as-errors, format, credo --strict,
                    # sobelow, deps.audit, dialyzer, test
```

`mix ci` is the same set plus `format --check-formatted` and coverage. Both
are also pixi tasks (`pixi run precommit`, `pixi run ci`).

Sobelow exits non-zero on any finding, so it gates both. Silence a false
positive with an entry in `.sobelow-conf` or an inline `# sobelow_skip`
comment, with a note saying why — not by loosening the threshold.

## Deployment

Runs as a single container on a NixOS host under podman. SQLite means
**exactly one instance** — a second would double-send reminders and fight
over the database file.

- [`Containerfile`](Containerfile) — multi-stage build producing an Elixir
  release. Build it as root on the host; `oci-containers` runs rootful and
  won't see an image built as your own user.
- [`deploy/afterlife.env.example`](deploy/afterlife.env.example) — every
  environment variable, required and optional.

```sh
sudo podman build -t localhost/afterlife:latest .

sudo install -d -m 0700 /etc/afterlife
sudo install -m 0600 deploy/afterlife.env.example /etc/afterlife/env
# ...then fill in the secrets

sudo nixos-rebuild switch
```

Migrations run at boot, so a deploy that starts is a deploy that migrated.
There is no separate migrate step.

Secrets live in `/etc/afterlife/env` (mode 0600), never in the Nix config —
everything in a Nix expression is copied into `/nix/store`, which is
world-readable.

## Operating it

**Monitoring.** Point an external uptime monitor at `https://<host>/health`
and alert on any non-200. On a freshly created database it returns 503
until the first sweep completes, up to 15 minutes.

**Backups.** The entire state is the SQLite file on the container's `/data`
volume. Take a consistent snapshot through the app's own connection rather
than copying the file, which can catch it mid-write:

```sh
sudo podman exec afterlife /app/bin/afterlife rpc \
  'Afterlife.Repo.query!("VACUUM INTO \'/data/snapshot.db\'")'
```

The result lands on the host side of the volume, ready to ship offsite.
Keep `CLOAK_KEY` somewhere other than alongside it — together they are the
whole system, separately they are each useless.

**Restoring.** Put the database back on the volume, set the same
`CLOAK_KEY`, start the container. Switches resume from their stored
`next_due_at`, so one that fell due while the app was down triggers on the
first sweep after it returns. That is intended, and worth thinking about
before restoring an old backup onto a live domain.

**Checking mail actually works**, without waiting for a reminder:

```sh
sudo podman exec afterlife /app/bin/afterlife rpc \
  'Afterlife.Mailer.deliver_text("you@example.com", "test", "hello") |> IO.inspect()'
```

Each switch's audit log records every reminder, check-in, and transition
with its channel and actor.
