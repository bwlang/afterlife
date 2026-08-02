defmodule AfterlifeWeb.HealthController do
  @moduledoc """
  Polled by an external uptime monitor (Montastic). Returns 503 — not
  200 — when the sweep worker has stopped running, so a monitor that
  only understands status codes still catches a wedged scheduler rather
  than just a down web server.

  Deliberately unauthenticated and outside the `:browser` pipeline: it
  is hit every minute and has to work when as little as possible is
  working.
  """

  use AfterlifeWeb, :controller

  alias Afterlife.Health

  def show(conn, _params) do
    case Health.sweep_status() do
      {:ok, age} ->
        text(conn, "ok: sweep completed #{age}s ago (build #{Health.version()})")

      {:error, :never_run} ->
        unhealthy(conn, "no sweep has completed yet")

      {:error, {:stale, age}} ->
        unhealthy(
          conn,
          "sweep last completed #{age}s ago, over the #{Health.stale_after_seconds()}s limit"
        )
    end
  end

  defp unhealthy(conn, reason) do
    conn
    |> put_status(:service_unavailable)
    |> text("UNHEALTHY: #{reason} (build #{Health.version()})")
  end
end
