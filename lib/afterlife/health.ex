defmodule Afterlife.Health do
  @moduledoc """
  Liveness of the sweep worker — the thing that actually makes this a
  dead-man's switch (docs/DESIGN.md §0).

  Reports the age of the last *completed* `SweepWorker` job rather than
  whether the web server answers. A container that happily serves pages
  while Oban is wedged is the failure that matters here, and from the
  outside it looks perfectly healthy: reminders silently stop, and the
  first symptom is a switch that fires — or doesn't — months later.

  Read by `AfterlifeWeb.HealthController` for an external monitor to
  poll. Nothing records this separately; Oban only marks a job
  `completed` when `perform/1` returned `:ok`, so its own bookkeeping is
  the authoritative record of a clean run.
  """

  import Ecto.Query

  alias Afterlife.Repo
  alias Afterlife.Switches.SweepWorker

  # The cron runs every 15 minutes (config/config.exs). Allow three
  # consecutive misses before reporting unhealthy, so a single slow or
  # retried run doesn't wake anyone at 3am.
  @stale_after_seconds 45 * 60

  @doc """
  `{:ok, age_in_seconds}` if a sweep completed recently, otherwise
  `{:error, :never_run}` or `{:error, {:stale, age_in_seconds}}`.
  """
  def sweep_status(now \\ DateTime.utc_now()) do
    case last_sweep_at() do
      nil ->
        {:error, :never_run}

      completed_at ->
        age = DateTime.diff(now, completed_at, :second)

        if age > @stale_after_seconds do
          {:error, {:stale, age}}
        else
          {:ok, age}
        end
    end
  end

  def stale_after_seconds, do: @stale_after_seconds

  @doc """
  The commit this build came from, baked in as `GIT_SHA` by the
  Containerfile. `"unknown"` when nothing passed it — a local
  `mix phx.server`, or a hand-run `podman build`.

  Reported next to the sweep age so a deploy can be confirmed rather
  than assumed: the git checkout and the image actually running are two
  different things, and they drift quietly.
  """
  def version do
    case System.get_env("GIT_SHA") do
      sha when is_binary(sha) and sha != "" -> String.slice(sha, 0, 8)
      _ -> "unknown"
    end
  end

  defp last_sweep_at do
    Repo.one(
      from j in Oban.Job,
        where: j.worker == ^inspect(SweepWorker) and j.state == "completed",
        select: max(j.completed_at)
    )
  end
end
