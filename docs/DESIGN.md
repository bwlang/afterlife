# afterlife — design doc (v0.1)

A self-hosted Phoenix app that holds messages for people you love and
delivers them if you stop checking in. Feature set modeled on
[deadmansswitch.email](https://www.deadmansswitch.email/), extended with
trusted-contact confirmation.

Scope decisions locked in for this version:
- **Audience**: personal/family use, not a public SaaS. A handful of user
  accounts (you, maybe your spouse), each with their own switch(es).
- **Check-in robustness**: email reminders, plus trusted contacts who
  can vouch ("they're fine, reset the clock") or confirm death ("send now").
  SMS is not a requirement — see §1a — and only gets built if it turns out
  to be a small addition on top of the email flow, not a parallel channel
  to design and maintain.
- **Hosting**: self-hosted, your own server — a Podman-run container image
  deployed onto NixOS.
- **Dev environment**: pixi (conda-forge) manages the Elixir/Erlang
  toolchain for reproducibility across machines.
- **Billing**: none. No Stripe, no tiers — everything the reference site
  gates behind its paid plan is just... on.

---

## 0. The risk that matters more than any feature

This app's entire job is to work correctly *after* the person who built and
maintains it can no longer intervene. That inverts the usual reliability
assumptions:

- If **you die** and the app is healthy → it must fire. That's the whole
  point, and it's the "easy" case to design for (state machine below).
- If **the server dies** (disk failure, the NixOS box losing power for
  good, you forget to renew a domain, a container reboot loop, an expired
  TLS cert nobody notices) while you're alive and well → the switch
  silently stops running and nobody ever finds out, until it's too late
  to matter.
- If **you die AND the server has quietly been down for a month** → nothing
  is ever delivered. This is the failure mode a self-hosted single-box
  deployment is most exposed to, and it's invisible by construction — there's
  no error, just silence.

Every other feature below is worth building. None of it matters if this
isn't addressed, so it's a first-class part of the design, not an ops
afterthought:

1. **External liveness monitor** (a *second*, independent dead-man's
   switch watching the first): a third-party service polls `GET /health`,
   which reports the age of the last **completed** Oban sweep and returns
   503 once that exceeds 45 minutes (three missed 15-minute runs). If the
   scheduler stops, or the host dies, or the app serves pages while Oban
   is wedged, that service — not this app — alerts you and/or a trusted
   contact directly. This is the one component deliberately kept
   *outside* the app, because the app itself is exactly what can't be
   trusted to notice its own death.

   Polling rather than the app pushing a ping outward: it covers the same
   failures (the monitor treats a dead host as a failed check), needs no
   credential or URL in the app's config, and keeps the network call —
   and anything that can go wrong with it — out of the critical job.
2. **Offsite encrypted backups** of the SQLite database file and attachment
   store (e.g. `restic`/`borgbackup` to cloud storage, nightly — a
   `sqlite3 .backup` snapshot before shipping it off, so we never back up
   a file mid-write), so the whole switch can be restored on new hardware
   if the box is lost outright.
3. **Boring, low-maintenance hosting**: the container is declared in the
   NixOS host config (`virtualisation.oci-containers`, backend `podman`)
   so systemd restarts it, not a hand-rolled supervisor; unattended OS
   security upgrades (NixOS makes this declarative); a domain/TLS renewal
   that's automated (not a manual step); and hosting billed somewhere that
   won't silently lapse (prepaid credit, or a card on file with a long
   runway and a calendar reminder — worth deciding explicitly, not a code
   problem but a "who pays for this after I'm gone" problem).
4. **Long reminder/grace windows by default** (weeks, not days) so a
   week of vacation or a lost phone doesn't come close to triggering
   anything — the state machine should be forgiving by default.

Recommend treating item 1 as part of the MVP, not phase 3 — it's cheap
(one endpoint and a URL pasted into a monitor) and it's the difference
between "silent failure" and "you get an email saying your
dead-man's-switch app died."

---

## 1. Feature scope by phase

### Phase 1 — MVP
- Accounts via `phx.gen.auth` (email/password; a handful of users).
- A **Switch**: check-in interval + grace period, status
  (active / grace / paused / triggered / cancelled).
- **Messages**: subject + body (rich text or plain), one or more
  recipients (name + email), file attachments, all encrypted at rest.
- **Check-in**: dashboard "I'm still here" button, plus a one-click,
  single-use, expiring link delivered in reminder emails.
- **API check-in**: a long-lived, per-switch, regenerable token
  (`GET/POST /api/check_in/:token`) so other tools/scripts — a
  presence monitor, a cron job, whatever the owner wires up — can
  check in programmatically, without waiting for a reminder email.
  Deliberately a *different* kind of token than the one-time emailed
  links: long-lived and switch-scoped rather than one-shot, since it's
  meant to be embedded in a script, not clicked once.
- Reminder emails on a schedule (e.g. T-7d, T-3d, T-1d), escalating
  subject lines as the deadline nears.
- Grace period after a missed check-in, then automatic delivery.
- LiveView dashboard: countdown, message list, check-in history/audit log.
- **`GET /health`** reporting sweep freshness, for an external monitor to poll (see §0).

### Phase 2 — trusted contacts
- **Trusted contacts** per switch: people who are *not* recipients of the
  final message, but who can, via an emailed link (no account needed):
  - **Vouch**: "I've spoken to them, they're fine" → resets the timer.
  - **Confirm passing**: → collapses the grace period and schedules
    delivery.
  - Require **N-of-M confirmation** (default 2-of-however-many) before a
    death confirmation is acted on, so one wrong click (or one bad-faith
    click) can't trigger delivery. A death confirmation still goes through
    a short, cancel-able countdown (e.g. 24h) rather than firing instantly.
- Full audit log surfaced in the dashboard: every reminder sent, every
  check-in, every vouch/confirm, with actor and channel.

### 1a. SMS — optional, only if cheap to add

Not in scope by default: email covers the check-in and trusted-contact
flows end to end, and a second channel (Twilio account, phone number
verification, delivery-status webhooks, its own retry/failure handling)
roughly doubles the surface area of every reminder/link/audit-log feature
above for a use case (you personally, plus family) where email reliably
reaches everyone.

Worth revisiting later *only* as a thin bolt-on: reuse the existing
`action_tokens` (same check-in/vouch/confirm links, just delivered by SMS
instead of email) rather than building parallel SMS-specific logic. If a
future need makes email-only insufficient (e.g. a recipient who doesn't
check email), add a single Twilio send call into the existing reminder
job — not a new channel to design around.

### Phase 3 — Hardening
- Offsite encrypted backups (SQLite file + attachments volume),
  automated restore drill documented.
- NixOS host config: the app container (podman), Caddy (TLS) as either
  a native NixOS service or its own container, and a systemd timer for
  the nightly backup job.
- Telemetry/logging + failure alerting (a failed Oban job emails you).
- Nice-to-haves worth considering once the core is solid: messages that
  aren't death-triggered at all but scheduled for a future date
  ("open on your 18th birthday"), test-send-to-self preview, message
  versioning.

---

## 2. Tech stack

| Concern | Choice | Why |
|---|---|---|
| Web/app framework | Phoenix + LiveView | Real-time dashboard (countdown, status) without a separate SPA; this is a small app, LiveView keeps it one codebase. |
| DB | **SQLite** (`ecto_sqlite3`/`exqlite`) | Single-node, family-scale traffic — Postgres would just be an extra service to run and back up for no benefit here. Ships as one file, lives on the mounted volume (below), backed up by copying that file. |
| Background jobs & scheduling | **Oban** (+ Oban Cron), engine `Oban.Engines.Lite` | This is the actual dead-man's-switch engine: a periodic sweep job checks every switch's `next_due_at`, sends reminders, advances grace state, fires delivery. Oban's SQLite engine is first-class/official, so no extra infra (no Redis, no Postgres) and no hand-rolled job runner. |
| Outbound email | Swoosh | Standard Phoenix mailer; adapter can be local SMTP relay or a transactional API (Mailgun/Postmark/SES) — your call at deploy time. Sole reminder/vouch/confirm channel for now (see §1a on SMS). |
| Field-level encryption | `Cloak.Ecto` | Encrypts message bodies and attachment blobs at rest — this is about as sensitive as personal data gets. |
| Magic links (check-in, delay, vouch, confirm) | Dedicated `action_tokens` table (hash stored, not the raw token) rather than bare `Phoenix.Token` | Need per-token expiry *and* revocation/one-time-use tracked in the audit log — a signed token alone can't be revoked or logged as "used". |
| File storage | Local volume, alongside the SQLite file | Self-hosted; encrypt-then-store either way. Same volume as the DB (below), so one backup job covers both. |
| Deployment | Podman-run OCI image on a NixOS server | App ships as a container image (built from an Elixir release). Declared via `virtualisation.oci-containers` (backend `podman`) in the host's NixOS config, so `restart`/supervision is systemd, not a Compose file. Because the DB is now a SQLite file rather than a separate Postgres service, the *only* deploy-time state to get right is a **persistent volume mount**: the container needs a host path (e.g. `/var/lib/afterlife`) bind-mounted in (via `virtualisation.oci-containers.containers.afterlife.volumes = ["/var/lib/afterlife:/data"]`) for the SQLite file + attachments, so replacing the image (a new deploy) never touches that data, and the nightly backup job on the *host* can read it without reaching into the container. |
| External liveness monitor | Montastic (or any HTTP uptime checker) polling `GET /health` | Deliberately outside the app — see §0. Pull, not push, so the network call stays out of the sweep job. |
| Dev toolchain | pixi (conda-forge: `elixir`, `erlang`) | Reproducible, pinned toolchain instead of relying on whatever's on the dev machine's PATH; also gives a `linux-64` env to sanity-check against before building the deploy image. |
| Static analysis | Credo (`--strict`) + Sobelow, same as `neb_product_database` | `mix precommit` (compile --warnings-as-errors, format, credo, test) and `mix ci` (+ sobelow, run in CI) — both pixi tasks too (`pixi run precommit` / `pixi run ci`). One deliberate deviation: `Credo.Check.Design.AliasUsage` is disabled in `.credo.exs` — it mostly fired on single-use references inside Phoenix's own generated boilerplate, not worth aliasing a module for one call site. `.sobelow-conf` ignores `Config.CSRFRoute` for the API check-in route (GET+POST on one action is fine there since it's bearer-token-authenticated, not session-cookie-authenticated — see the comment in `router.ex`) and honors inline `# sobelow_skip` comments (`skip: true`). |

---

## 3. Domain model (sketch)

```
users
  id, email, hashed_password, inserted_at

switches
  id, user_id, name
  check_in_interval_days      # e.g. 30
  grace_period_days           # e.g. 7
  status                      # :active | :grace | :paused | :triggered | :cancelled
  last_check_in_at
  next_due_at                 # denormalized, recomputed on check-in

messages
  id, switch_id, subject, body_ciphertext, inserted_at, updated_at

recipients
  id, message_id, name, email, phone (optional)

attachments
  id, message_id, filename, content_type, byte_size, storage_ref (ciphertext)

trusted_contacts
  id, switch_id, name, email, phone, relationship

check_in_events                # append-only audit log
  id, switch_id, type          # :reminder_sent | :delay_clicked | :manual_checkin
                                # | :trusted_vouch | :trusted_confirm_death
  channel                      # :email | :dashboard (leave room for :sms later)
  actor                        # user_id or trusted_contact_id
  occurred_at

action_tokens
  id, switch_id, trusted_contact_id (nullable), purpose
  token_hash, expires_at, used_at

delivery_logs
  id, message_id, recipient_id, channel, status, sent_at, error
```

## 4. Check-in / escalation state machine

```
active ──(missed check-in by next_due_at)──▶ grace
active ──(check-in: dashboard, emailed link, or trusted vouch)──▶ active (timer reset)
grace  ──(check-in of any kind)──▶ active (timer reset)
grace  ──(grace_period_days elapses with no check-in)──▶ triggered
grace  ──(N-of-M trusted contacts confirm death)──▶ triggered
                                                        │ (after cancel-able countdown)
                                                        ▼
triggered ──(Oban delivers all messages to all recipients)──▶ done
any state ──(user pauses)──▶ paused ──(user resumes)──▶ active
```

Oban's cron-scheduled sweep is the only thing that moves switches between
`active` → `grace` → `triggered`; everything else (check-ins, vouches) just
writes a `check_in_events` row and recomputes `next_due_at` /
`status` inline.

---

## 5. Open questions to settle before/while scaffolding

- Default interval/grace values (reference site implies check-in weekly,
  message expiring after a year on free tier — we're not tier-gating, but
  still need sane defaults, e.g. 30-day interval / 7-day grace).
- Exact trusted-contact quorum rule (2-of-N flat, or scale with N?) and
  length of the pre-delivery cancel window.
- Which email provider/credentials you want to use in practice
  (affects the Swoosh adapter config, not the design).
- Where backups land (which cloud storage account/bucket) and who besides
  you can restore from them.

---

## 6. Testing strategy

- ExUnit + `Ecto.Adapters.SQL.Sandbox` for schema/context tests as usual.
- Oban's `Oban.Testing` helpers to assert jobs are enqueued/executed
  without wall-clock sleeps — critical here since the whole app is a
  scheduler. **Caveat hit in practice**: `assert_enqueued/1` builds an
  `Oban.Config` that hardcodes the Postgres notifier at validation time
  and blows up under the Lite (SQLite) engine, regardless of our actual
  `notifier: Oban.Notifiers.PG` config. Workaround: assert directly
  against the `oban_jobs` table via a plain Ecto query instead — fully
  adapter-agnostic, and what `test/afterlife/switches_test.exs` does.
- Property/scenario tests around the state machine itself (missed
  check-in → grace → triggered; check-in during grace resets; vouch vs.
  confirm-death race; quorum math) since that logic is the product.
- A documented manual "fire drill": pause a switch, fast-forward its
  `next_due_at` in a staging DB, and confirm delivery actually happens
  end-to-end (SMTP + attachments + all recipients) — worth doing after
  every change to the scheduler.
