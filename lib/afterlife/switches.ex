defmodule Afterlife.Switches do
  @moduledoc """
  The Switches context: the dead-man's-switch state machine described in
  docs/DESIGN.md §4.

      active ──(missed check-in by next_due_at)──▶ grace
      active ──(any check-in)──▶ active (timer reset)
      grace  ──(any check-in)──▶ active (timer reset)
      grace  ──(grace_period_days elapses)──▶ triggered
      any    ──(pause)──▶ paused ──(resume)──▶ active

  `next_due_at` always means "the next time something happens if nobody
  checks in" — it's recomputed from `last_check_in_at` plus the switch's
  configured durations every time status or those durations change,
  rather than incremented in place, so it can't drift or compound if a
  sweep runs late.

  This module owns the state machine and audit log; it does not send
  reminders or deliver messages — that's the Oban sweep worker (which
  calls `due_for_transition/1` and `advance_state/2` from here).
  """

  import Ecto.Query, warn: false

  alias Afterlife.Accounts.User
  alias Afterlife.Repo
  alias Ecto.Changeset

  alias Afterlife.Switches.{
    ActionToken,
    Attachment,
    CheckInEvent,
    DeliveryLog,
    DeliveryWorker,
    Message,
    MessageRecipient,
    Recipient,
    Switch
  }

  # The statuses that are counting down towards something — the only
  # ones the sweep worker has to look at.
  @counting_down ~w(active grace)

  ## CRUD

  def list_switches(%User{} = user) do
    Repo.all(from s in Switch, where: s.user_id == ^user.id, order_by: [asc: s.name])
  end

  def get_switch!(%User{} = user, id) do
    Repo.get_by!(Switch, id: id, user_id: user.id)
  end

  def change_switch(%Switch{} = switch, attrs \\ %{}) do
    Switch.changeset(switch, attrs)
  end

  @doc """
  Creates a switch for `user`, starting it in the `active` state as of
  now (i.e. the owner has just "checked in" by creating it).
  """
  def create_switch(%User{} = user, attrs) do
    %Switch{}
    |> Switch.changeset(attrs)
    |> Changeset.change(
      user_id: user.id,
      status: "active",
      last_check_in_at: DateTime.utc_now(:second)
    )
    |> put_next_due_at()
    |> Repo.insert()
  end

  @doc """
  Updates a switch's name/interval/grace period. If the interval or
  grace period changes, `next_due_at` is recomputed against the
  switch's existing `last_check_in_at` — editing the settings is not a
  check-in.
  """
  def update_switch_settings(%Switch{} = switch, attrs) do
    switch
    |> Switch.changeset(attrs)
    |> put_next_due_at()
    |> Repo.update()
  end

  ## Messages / recipients / attachments

  @doc """
  A switch's messages, with recipients and attachment *metadata*
  preloaded. Attachment contents are deliberately left out: they can be
  tens of megabytes each, and only the delivery path
  (`get_message_with_recipient!/2`) ever needs them.
  """
  def list_messages(%Switch{} = switch) do
    attachment_metadata =
      from a in Attachment,
        select: struct(a, [:id, :message_id, :filename, :content_type, :byte_size, :inserted_at])

    from(m in Message, where: m.switch_id == ^switch.id, order_by: [asc: m.inserted_at])
    |> Repo.all()
    |> Repo.preload([
      :recipients,
      [message_recipients: :recipient],
      attachments: attachment_metadata
    ])
    |> Enum.map(&Map.put(&1, :schedule, delivery_schedule(&1)))
  end

  def change_message(%Message{} = message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end

  @doc """
  Creates a message on `switch`, addressed to the given recipient ids.

  Ids are filtered to the switch's own recipients, so a forged id from
  another switch links nothing rather than leaking a message to a
  stranger.
  """
  def create_message(%Switch{} = switch, attrs, schedules \\ []) do
    owned = Repo.all(from r in Recipient, where: r.switch_id == ^switch.id, select: r.id)

    links =
      schedules
      |> Enum.filter(&(&1.recipient_id in owned))
      |> Enum.map(&MessageRecipient.changeset(%MessageRecipient{}, &1))

    %Message{}
    |> Message.changeset(attrs)
    |> Changeset.put_change(:switch_id, switch.id)
    |> Changeset.put_assoc(:message_recipients, links)
    |> Repo.insert()
  end

  ## Recipients (people on a switch, reused across its messages)

  def list_recipients(%Switch{} = switch) do
    Repo.all(from r in Recipient, where: r.switch_id == ^switch.id, order_by: [asc: r.name])
  end

  def get_recipient!(%Switch{} = switch, id) do
    Repo.get_by!(Recipient, id: id, switch_id: switch.id)
  end

  def change_recipient(%Recipient{} = recipient, attrs \\ %{}) do
    Recipient.changeset(recipient, attrs)
  end

  def add_recipient(%Switch{} = switch, attrs) do
    %Recipient{}
    |> Recipient.changeset(Map.put(attrs, :switch_id, switch.id))
    |> Repo.insert()
  end

  def update_recipient(%Recipient{} = recipient, attrs) do
    recipient
    |> Recipient.changeset(attrs)
    |> Repo.update()
  end

  def delete_recipient(%Recipient{} = recipient), do: Repo.delete(recipient)

  def add_attachment(%Message{} = message, attrs) do
    %Attachment{}
    |> Attachment.changeset(Map.put(attrs, :message_id, message.id))
    |> Repo.insert()
  end

  ## Check-in (resets the timer, always back to `active`)

  @doc "Owner clicked \"I'm still here\" on the dashboard."
  def manual_check_in(%Switch{} = switch) do
    check_in(switch, type: "manual_checkin", channel: "dashboard", actor_id: switch.user_id)
  end

  @doc "Owner clicked the delay link in a reminder email."
  def check_in_via_link(%Switch{} = switch) do
    check_in(switch, type: "delay_clicked", channel: "email", actor_id: switch.user_id)
  end

  @doc "A trusted contact vouched that the owner is fine."
  def trusted_vouch(%Switch{} = switch, trusted_contact_id) do
    check_in(switch,
      type: "trusted_vouch",
      channel: "email",
      actor_type: "trusted_contact",
      actor_id: trusted_contact_id
    )
  end

  # Every check-in has the same effect whatever the channel — back to
  # active, timer restarted from now — and differs only in what gets
  # written to the audit log.
  defp check_in(%Switch{} = switch, event_attrs) do
    now = DateTime.utc_now(:second)

    update_and_log(
      switch,
      [
        status: "active",
        last_check_in_at: now,
        next_due_at: compute_next_due_at("active", now, switch)
      ],
      event_attrs |> Keyword.put_new(:actor_type, "user") |> Map.new()
    )
  end

  ## External API check-ins (for other tools/scripts, not email links)

  @doc """
  Generates (or regenerates) a switch's long-lived API token, for other
  tools/scripts to check in programmatically. Returns
  `{:ok, raw_token, switch}` — the raw token is shown once and only its
  hash is stored; regenerating immediately invalidates any prior token.
  """
  def regenerate_api_token(%Switch{} = switch) do
    raw_token = :crypto.strong_rand_bytes(32)
    hashed_token = :crypto.hash(:sha256, raw_token)

    case switch |> Changeset.change(api_token_hash: hashed_token) |> Repo.update() do
      {:ok, updated} -> {:ok, Base.url_encode64(raw_token, padding: false), updated}
      error -> error
    end
  end

  def get_switch_by_api_token(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} ->
        hashed_token = :crypto.hash(:sha256, decoded)
        Repo.get_by(Switch, api_token_hash: hashed_token)

      :error ->
        nil
    end
  end

  @doc """
  Checks in via a switch's API token. Returns `{:ok, switch}` or
  `{:error, :invalid_token}`.

  `ip_address` is recorded on the audit event: this token is long-lived
  and resets the switch, so an address the owner doesn't recognise is
  the signal that it has leaked.
  """
  def check_in_via_api(raw_token, ip_address \\ nil) do
    case get_switch_by_api_token(raw_token) do
      nil ->
        {:error, :invalid_token}

      switch ->
        check_in(switch,
          type: "api_check_in",
          channel: "api",
          actor_id: switch.user_id,
          ip_address: ip_address
        )
    end
  end

  ## Magic links

  @doc """
  Generates the raw, URL-safe token for a reminder email's delay link.
  Embed it in a URL; nothing but its hash is stored.
  """
  def generate_check_in_token(%Switch{} = switch) do
    ActionToken.generate(switch, "check_in")
  end

  @doc """
  Consumes a check-in link's raw token: verifies it (valid, unexpired,
  unused — and atomically marks it used so it can't be replayed), then
  performs the check-in. Returns `{:ok, switch}` or
  `{:error, :invalid_or_expired}`.
  """
  def check_in_via_token(raw_token, ip_address \\ nil) do
    with {:ok, %ActionToken{switch: switch}} <-
           ActionToken.verify_and_consume(raw_token, "check_in") do
      check_in(switch,
        type: "delay_clicked",
        channel: "email",
        actor_id: switch.user_id,
        ip_address: ip_address
      )
    end
  end

  ## Pause / resume

  def pause_switch(%Switch{} = switch) do
    update_and_log(switch, [status: "paused", next_due_at: nil], %{
      type: "paused",
      channel: "dashboard",
      actor_type: "user",
      actor_id: switch.user_id
    })
  end

  @doc """
  Resumes a paused switch. Resuming *is* a check-in — the countdown
  restarts from now, not from wherever it was when the switch was
  paused — so it only differs from `manual_check_in/1` in what it logs.
  """
  def resume_switch(%Switch{} = switch) do
    check_in(switch, type: "resumed", channel: "dashboard", actor_id: switch.user_id)
  end

  ## Scheduler-facing: state transitions on missed check-ins

  @doc """
  Active or grace switches whose deadline has passed — the sweep
  worker's queue of "something must happen to this switch now".
  """
  def due_for_transition(now \\ DateTime.utc_now(:second)) do
    Repo.all(from s in Switch, where: s.status in @counting_down and s.next_due_at <= ^now)
  end

  # active ─▶ grace ─▶ triggered: one missed deadline moves a switch
  # exactly one step down this chain, with the matching audit event.
  @next_state %{
    "active" => {"grace", "entered_grace"},
    "grace" => {"triggered", "triggered"}
  }

  @doc """
  Advances a switch exactly one step: `active` → `grace` on a missed
  check-in, or `grace` → `triggered` once the grace period elapses.
  No-op (returns `{:ok, switch}` unchanged) for any other status or if
  the switch isn't actually due yet.
  """
  def advance_state(%Switch{status: status, next_due_at: %DateTime{} = due} = switch, now)
      when is_map_key(@next_state, status) do
    if DateTime.after?(due, now) do
      {:ok, switch}
    else
      {next_status, event_type} = Map.fetch!(@next_state, status)
      transition(switch, next_status, event_type)
    end
  end

  def advance_state(%Switch{} = switch, _now), do: {:ok, switch}

  # Not a full day, so a sweep that runs a little later each day (or an
  # operator re-running one by hand) still sends the next reminder.
  @reminder_quiet_period_hours 20

  @doc """
  Active or grace switches due within the next week that haven't had a
  reminder sent in the last #{@reminder_quiet_period_hours} hours — the
  sweep worker's reminder queue. Deliberately a loose "at least daily
  starting a week out" cadence rather than exact T-7/T-3/T-1 buckets:
  simpler to reason about and forgiving by default (see docs/DESIGN.md §0).
  """
  def switches_needing_reminder(now \\ DateTime.utc_now(:second)) do
    soon = DateTime.add(now, 7, :day)
    quiet_since = DateTime.add(now, -@reminder_quiet_period_hours, :hour)

    reminded_recently =
      from e in CheckInEvent,
        where:
          e.switch_id == parent_as(:switch).id and e.type == "reminder_sent" and
            e.inserted_at > ^quiet_since

    Repo.all(
      from s in Switch,
        as: :switch,
        where: s.status in @counting_down and s.next_due_at > ^now and s.next_due_at <= ^soon,
        where: not exists(reminded_recently)
    )
  end

  def record_reminder_sent(%Switch{} = switch) do
    log_event(switch, %{type: "reminder_sent", channel: "email", actor_type: "system"})
  end

  @doc """
  Enqueues one delivery job per (message, recipient) for a triggered
  switch. Safe to call repeatedly — jobs are unique on their args, so
  re-running it never double-sends.

  Raises rather than returning an error: it runs inside the triggering
  transaction (see `transition/3`), where a failure must abort the
  status change too.
  """
  def enqueue_delivery(%Switch{status: "triggered"} = switch, now \\ DateTime.utc_now(:second)) do
    links =
      Repo.all(
        from mr in MessageRecipient,
          join: m in Message,
          on: m.id == mr.message_id,
          where: m.switch_id == ^switch.id,
          select: {mr.message_id, mr.recipient_id, mr.deliver_on}
      )

    for {message_id, recipient_id, deliver_on} <- links do
      deliver_after = deliver_after(deliver_on, now)

      {:ok, log} = get_or_create_delivery_log(message_id, recipient_id, deliver_after)

      if is_nil(log.deliver_after), do: enqueue_delivery_job(message_id, recipient_id)
    end

    :ok
  end

  @doc """
  When a scheduled copy becomes due, as a datetime — `nil` meaning "as
  soon as the switch triggers".

  A date already in the past resolves to nil rather than staying
  pending: failing towards delivery is the safe direction, since a
  letter arriving early is recoverable and one that never arrives is
  not.
  """
  def deliver_after(deliver_on, now \\ DateTime.utc_now())

  def deliver_after(nil, _now), do: nil

  def deliver_after(%Date{} = deliver_on, now) do
    due = DateTime.new!(deliver_on, ~T[09:00:00], "Etc/UTC")

    if DateTime.after?(due, now), do: due, else: nil
  end

  @doc """
  The date someone born on `birthdate` turns `age`.

  An input-layer convenience for turning "when they turn 18" into the
  date the delivery path actually stores. A 29 February birthdate has
  no anniversary in most years, so it falls back to the 28th rather
  than skipping three years in four.
  """
  def birthday_at_age(%Date{} = birthdate, age) when is_integer(age) and age >= 0 do
    year = birthdate.year + age

    case Date.new(year, birthdate.month, birthdate.day) do
      {:ok, date} ->
        date

      {:error, _} ->
        Date.new!(year, birthdate.month, Date.days_in_month(%{birthdate | year: year}))
    end
  end

  @doc """
  `{recipient, datetime_or_nil}` for each copy of `message`, for
  display. nil means "as soon as the switch triggers".
  """
  def delivery_schedule(%Message{} = message, now \\ DateTime.utc_now()) do
    message = Repo.preload(message, message_recipients: :recipient)

    Enum.map(message.message_recipients, fn link ->
      {link.recipient, deliver_after(link.deliver_on, now)}
    end)
  end

  @doc """
  Deliveries whose scheduled date has arrived. Called by the sweep, so
  a message held for a future birthday is picked up whenever the app is
  next running — not by a queue entry that had to survive until then.
  """
  def enqueue_due_deliveries(now \\ DateTime.utc_now(:second)) do
    due =
      Repo.all(
        from l in DeliveryLog,
          where:
            l.status == "pending" and not is_nil(l.deliver_after) and l.deliver_after <= ^now,
          select: {l.message_id, l.recipient_id}
      )

    Enum.each(due, fn {message_id, recipient_id} ->
      enqueue_delivery_job(message_id, recipient_id)
    end)
  end

  # Inserted one at a time rather than via `Oban.insert_all/1`, which
  # doesn't enforce job uniqueness on the basic (non-Pro) engine.
  defp enqueue_delivery_job(message_id, recipient_id) do
    %{message_id: message_id, recipient_id: recipient_id}
    |> DeliveryWorker.new()
    |> Oban.insert!()
  end

  @doc """
  Messages and their recipients for a triggered switch, with
  attachments preloaded — what `DeliveryWorker` actually sends.
  """
  def get_message_with_recipient!(message_id, recipient_id) do
    message =
      Message
      |> Repo.get!(message_id)
      |> Repo.preload(:attachments)

    recipient = Repo.get!(Recipient, recipient_id)
    {message, recipient}
  end

  @doc "Finds or creates the pending delivery_log row for a (message, recipient) pair."
  def get_or_create_delivery_log(message_id, recipient_id, deliver_after \\ nil) do
    case Repo.get_by(DeliveryLog, message_id: message_id, recipient_id: recipient_id) do
      nil ->
        %DeliveryLog{}
        |> DeliveryLog.changeset(%{
          message_id: message_id,
          recipient_id: recipient_id,
          deliver_after: deliver_after
        })
        |> Repo.insert()

      log ->
        {:ok, log}
    end
  end

  def mark_delivery_sent(%DeliveryLog{} = log) do
    log
    |> DeliveryLog.changeset(%{status: "sent", sent_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  def mark_delivery_failed(%DeliveryLog{} = log, error) do
    log
    |> DeliveryLog.changeset(%{status: "failed", error: inspect(error)})
    |> Repo.update()
  end

  # Triggering must also schedule the delivery jobs, in the *same*
  # transaction: `due_for_transition/1` only returns active/grace
  # switches, so nothing revisits one that already reads "triggered".
  # All of it lands, or none of it does and the next sweep retries.
  defp transition(%Switch{} = switch, "triggered" = new_status, event_type) do
    transition(switch, new_status, event_type, &enqueue_delivery/1)
  end

  defp transition(%Switch{} = switch, new_status, event_type) do
    transition(switch, new_status, event_type, fn _switch -> :ok end)
  end

  defp transition(%Switch{} = switch, new_status, event_type, and_then) do
    update_and_log(
      switch,
      [
        status: new_status,
        next_due_at: compute_next_due_at(new_status, switch.last_check_in_at, switch)
      ],
      %{type: event_type, channel: "system", actor_type: "system"},
      and_then
    )
  end

  # Every status change is an update plus its audit-log row, always
  # together: a status the log can't account for is worse than no
  # change at all, so either both land or neither does. `and_then` runs
  # inside the same transaction for the work that must be atomic with
  # the status change; it raises to abort.
  defp update_and_log(%Switch{} = switch, changes, event_attrs, and_then \\ fn _switch -> :ok end) do
    Repo.transact(fn ->
      with {:ok, updated} <- switch |> Changeset.change(changes) |> Repo.update(),
           {:ok, _event} <- log_event(updated, event_attrs) do
        and_then.(updated)
        {:ok, updated}
      end
    end)
  end

  ## Audit log

  # Automated check-ins (a terminal, a cron) make this the
  # fastest-growing table in the schema, and the dashboard renders every
  # row it's given. Bounded so the page cost stays flat however long a
  # switch has been running; the rows themselves are never deleted.
  @recent_events_limit 1000

  def list_check_in_events(%Switch{} = switch) do
    Repo.all(
      from e in CheckInEvent,
        where: e.switch_id == ^switch.id,
        order_by: [desc: e.inserted_at],
        limit: @recent_events_limit
    )
  end

  defp log_event(%Switch{} = switch, attrs) do
    %CheckInEvent{}
    |> CheckInEvent.changeset(Map.put(attrs, :switch_id, switch.id))
    |> Repo.insert()
  end

  ## next_due_at derivation

  defp put_next_due_at(changeset) do
    next_due_at =
      compute_next_due_at(
        Changeset.get_field(changeset, :status),
        Changeset.get_field(changeset, :last_check_in_at),
        Changeset.get_field(changeset, :check_in_interval_days),
        Changeset.get_field(changeset, :grace_period_days)
      )

    Changeset.put_change(changeset, :next_due_at, next_due_at)
  end

  defp compute_next_due_at(status, anchor, %Switch{} = switch) do
    compute_next_due_at(status, anchor, switch.check_in_interval_days, switch.grace_period_days)
  end

  # An active switch is due one interval after its last check-in; one in
  # grace is due the interval plus the grace period after it. Anything
  # else — paused, triggered, or a switch whose settings haven't passed
  # validation yet — isn't counting down at all.
  defp compute_next_due_at("active", %DateTime{} = anchor, interval, _grace)
       when is_integer(interval) do
    DateTime.add(anchor, interval, :day)
  end

  defp compute_next_due_at("grace", %DateTime{} = anchor, interval, grace)
       when is_integer(interval) and is_integer(grace) do
    DateTime.add(anchor, interval + grace, :day)
  end

  defp compute_next_due_at(_status, _anchor, _interval, _grace), do: nil
end
