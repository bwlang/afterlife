# afterlife — how it works

Companion to [DESIGN.md](DESIGN.md) (rationale/decisions). This doc is
diagrams of the system as built, for orienting in the code.

## 1. Components

```mermaid
flowchart TB
    Owner(["Owner<br/>(browser)"])
    Script(["External script / cron"])
    Recipients(["Message recipients<br/>(email)"])
    Monitor(["External uptime monitor<br/>e.g. Montastic"])

    subgraph App["Phoenix app"]
        LV["LiveView dashboard<br/>SwitchLive.*, MessageLive.*"]
        WebCheckIn["CheckInController<br/>GET /check-in/:token"]
        ApiCheckIn["Api.CheckInController<br/>GET/POST /api/check_in/:token"]
        Switches["Switches context<br/>state machine + audit log"]
        Vault["Cloak.Vault<br/>encrypt/decrypt"]
        Sweep["SweepWorker<br/>Oban cron, every 15 min"]
        Health["HealthController<br/>GET /health"]
        Delivery["DeliveryWorker<br/>Oban, queue :mailers"]
        Notifier["Notifier<br/>builds emails"]
    end

    DB[("SQLite<br/>priv/*/afterlife.db")]

    Owner -->|clicks dashboard button| LV
    Owner -->|clicks emailed link| WebCheckIn
    Script -->|bearer-token ping| ApiCheckIn

    LV --> Switches
    WebCheckIn --> Switches
    ApiCheckIn --> Switches
    Switches <--> DB
    Switches -. encrypt/decrypt message bodies & attachments .-> Vault

    Sweep --> Switches
    Sweep --> Notifier
    Sweep -->|enqueues on trigger| Delivery
    Delivery --> Switches
    Delivery --> Notifier
    Notifier -->|reminder| Owner
    Notifier -->|final message + attachments| Recipients
    Monitor -."polls GET /health<br/>(503 if sweep is stale)".-> Health
```

The `Switches` context ([`lib/afterlife/switches.ex`](../lib/afterlife/switches.ex))
is the only thing that touches the database for switch-related tables —
every entry point (LiveView, both controllers, both workers) goes
through it rather than querying `Repo` directly.

## 2. The switch state machine

```mermaid
stateDiagram-v2
    [*] --> active: create_switch

    active --> active: check-in\n(dashboard / email link / API token)
    active --> grace: next_due_at passes\n(missed check-in)
    grace --> active: check-in\n(any channel — resets fully)
    grace --> triggered: grace_period_days elapses

    active --> paused: pause_switch
    grace --> paused: pause_switch
    paused --> active: resume_switch

    triggered --> [*]: DeliveryWorker sends\nevery message to every recipient
```

`next_due_at` always means "the next time something happens if nobody
checks in" — recomputed from `last_check_in_at` on every transition
rather than incremented, so it can't drift. See
[`Switches.advance_state/2`](../lib/afterlife/switches.ex) and
[DESIGN.md §4](DESIGN.md#4-check-in--escalation-state-machine).

## 3. Checking in — three channels, one effect

```mermaid
sequenceDiagram
    actor Owner
    participant Script as External script/cron
    participant Web as Controller / LiveView
    participant Ctx as Switches context
    participant DB as SQLite

    alt Dashboard button
        Owner->>Web: click "I'm still here"
        Web->>Ctx: manual_check_in(switch)
    else Emailed magic link (one-time, expiring)
        Owner->>Web: GET /check-in/:token
        Web->>Ctx: check_in_via_token(token)
        Ctx->>Ctx: ActionToken.verify_and_consume/2<br/>(hash lookup, atomic used_at claim)
    else Long-lived API token
        Script->>Web: GET or POST /api/check_in/:token
        Web->>Ctx: check_in_via_api(token)
    end

    Ctx->>DB: status = "active"<br/>last_check_in_at = now<br/>next_due_at = now + interval
    Ctx->>DB: insert check_in_event<br/>(type, channel, actor — audit trail)
```

Every path funnels into the same private `check_in/2` — the only
difference between them is which `type`/`channel` gets logged. See
[`lib/afterlife_web/controllers/check_in_controller.ex`](../lib/afterlife_web/controllers/check_in_controller.ex)
and [`.../controllers/api/check_in_controller.ex`](../lib/afterlife_web/controllers/api/check_in_controller.ex).

## 4. The sweep: reminders, triggering, delivery

```mermaid
sequenceDiagram
    participant Cron as Oban Cron<br/>(*/15 * * * *)
    participant Sweep as SweepWorker
    participant Ctx as Switches
    participant Notifier
    actor Owner
    participant Oban as Oban queue
    participant Deliv as DeliveryWorker
    actor Recipient

    Cron->>Sweep: perform/1

    rect rgba(120, 120, 200, 0.08)
    note over Sweep,Owner: Reminders — due within 7 days, at most once/day
    Sweep->>Ctx: switches_needing_reminder(now)
    loop each due switch
        Sweep->>Ctx: generate_check_in_token(switch)
        Sweep->>Notifier: deliver_reminder(owner, switch, url)
        Notifier->>Owner: email (escalating tone: active → grace)
        Sweep->>Ctx: record_reminder_sent(switch)
    end
    end

    rect rgba(200, 120, 120, 0.08)
    note over Sweep,Oban: State transitions
    Sweep->>Ctx: due_for_transition(now)
    loop each switch past its deadline
        Sweep->>Ctx: advance_state(switch, now)
        alt became "triggered"
            Sweep->>Ctx: enqueue_delivery(switch)
            Ctx->>Oban: insert DeliveryWorker job per (message, recipient)<br/>unique — safe to re-enqueue
        end
    end
    end

    Sweep->>HB: ping — only if every step above succeeded
    note right of HB: A crash mid-sweep means no ping,<br/>which is the point: the monitor notices<br/>the scheduler going silent (see DESIGN.md §0)

    Oban->>Deliv: perform(job)
    Deliv->>Notifier: deliver_final_message(message, recipient)
    Notifier->>Recipient: final email + attachments
    Deliv->>Ctx: mark_delivery_sent/failed
```

See [`SweepWorker`](../lib/afterlife/switches/sweep_worker.ex) and
[`DeliveryWorker`](../lib/afterlife/switches/delivery_worker.ex).

## 5. Domain model

```mermaid
erDiagram
    USERS ||--o{ SWITCHES : owns
    SWITCHES ||--o{ MESSAGES : contains
    SWITCHES ||--o{ TRUSTED_CONTACTS : has
    SWITCHES ||--o{ CHECK_IN_EVENTS : logs
    SWITCHES ||--o{ ACTION_TOKENS : issues
    MESSAGES ||--o{ RECIPIENTS : "addressed to"
    MESSAGES ||--o{ ATTACHMENTS : includes
    MESSAGES ||--o{ DELIVERY_LOGS : "tracked by"
    RECIPIENTS ||--o{ DELIVERY_LOGS : receives
    TRUSTED_CONTACTS |o--o{ ACTION_TOKENS : "may hold (vouch/confirm — phase 2)"

    USERS {
        int id PK
        string email
        string hashed_password
    }
    SWITCHES {
        int id PK
        int user_id FK
        string name
        int check_in_interval_days
        int grace_period_days
        string status "active/grace/paused/triggered/cancelled"
        datetime last_check_in_at
        datetime next_due_at
        binary api_token_hash "nullable, unique"
    }
    MESSAGES {
        int id PK
        int switch_id FK
        binary subject "encrypted (Cloak)"
        binary body "encrypted (Cloak)"
    }
    RECIPIENTS {
        int id PK
        int message_id FK
        string name
        string email
    }
    ATTACHMENTS {
        int id PK
        int message_id FK
        string filename
        string content_type
        binary content "encrypted (Cloak)"
    }
    TRUSTED_CONTACTS {
        int id PK
        int switch_id FK
        string name
        string email
        string relationship
    }
    CHECK_IN_EVENTS {
        int id PK
        int switch_id FK
        string type "reminder_sent/delay_clicked/manual_checkin/..."
        string channel "email/dashboard/api/system"
        string actor_type "user/trusted_contact/system"
    }
    ACTION_TOKENS {
        int id PK
        int switch_id FK
        int trusted_contact_id FK
        string purpose "check_in/vouch/confirm_death"
        binary token_hash "unique, never the raw token"
        datetime expires_at
        datetime used_at "one-time use"
    }
    DELIVERY_LOGS {
        int id PK
        int message_id FK
        int recipient_id FK
        string status "pending/sent/failed"
        datetime sent_at
        string error
    }
```

`TRUSTED_CONTACTS`/vouch-and-confirm logic is schema-only right now —
Phase 2 per [DESIGN.md](DESIGN.md); everything else in this document is
built, tested, and running.
