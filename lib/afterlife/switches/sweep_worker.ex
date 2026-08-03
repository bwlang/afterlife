defmodule Afterlife.Switches.SweepWorker do
  @moduledoc """
  The dead-man's-switch engine, run on a cron schedule (config/config.exs).
  Each run sends due reminders, advances any switch whose deadline has
  passed, and releases deliveries that were held for a future date.

  Whether this job is still running at all is watched from outside, by
  an external monitor polling `GET /health` (docs/DESIGN.md §0) — that
  endpoint reports the age of the last *completed* run of this worker,
  via `Afterlife.Health`. Oban only marks a job completed when
  `perform/1` returns `:ok`, so a crash here shows up as staleness
  without this module needing to report anything itself.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Afterlife.Accounts
  alias Afterlife.Switches
  alias Afterlife.Switches.{Notifier, Switch}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now(:second)

    send_reminders(now)
    advance_states(now)
    Switches.enqueue_due_deliveries(now)

    :ok
  end

  defp send_reminders(now) do
    now
    |> Switches.switches_needing_reminder()
    |> Enum.each(&send_reminder/1)
  end

  defp send_reminder(%Switch{} = switch) do
    with {:ok, raw_token} <- Switches.generate_check_in_token(switch) do
      owner = Accounts.get_user!(switch.user_id)
      url = check_in_url(raw_token)

      case Notifier.deliver_reminder(owner, switch, url) do
        {:ok, _email} -> Switches.record_reminder_sent(switch)
        error -> error
      end
    end
  end

  # Triggering enqueues its own delivery jobs atomically with the status
  # change (see Switches.transition/3), so there is no enqueue step here.
  defp advance_states(now) do
    now
    |> Switches.due_for_transition()
    |> Enum.each(&Switches.advance_state(&1, now))
  end

  defp check_in_url(raw_token) do
    AfterlifeWeb.Endpoint.url() <> "/check-in/" <> raw_token
  end
end
