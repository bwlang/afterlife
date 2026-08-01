defmodule AfterlifeWeb.HealthControllerTest do
  use AfterlifeWeb.ConnCase

  alias Afterlife.Repo
  alias Afterlife.Switches.SweepWorker

  defp sweep_completed_at(datetime) do
    Repo.insert!(%Oban.Job{
      worker: inspect(SweepWorker),
      queue: "default",
      state: "completed",
      args: %{},
      inserted_at: datetime,
      scheduled_at: datetime,
      completed_at: datetime
    })
  end

  test "503 when no sweep has ever completed", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert conn.status == 503
    assert response(conn, 503) =~ "no sweep has completed yet"
  end

  test "200 when a sweep completed recently", %{conn: conn} do
    sweep_completed_at(DateTime.utc_now() |> DateTime.add(-60, :second))

    conn = get(conn, ~p"/health")

    assert conn.status == 200
    assert response(conn, 200) =~ "ok: sweep completed"
  end

  # The failure this endpoint exists for: the web server is fine, so an
  # ordinary uptime check sees 200, while the scheduler has silently
  # stopped and no reminders are going out.
  test "503 when the app is serving but the sweep has gone stale", %{conn: conn} do
    sweep_completed_at(DateTime.utc_now() |> DateTime.add(-3, :hour))

    conn = get(conn, ~p"/health")

    assert conn.status == 503
    assert response(conn, 503) =~ "UNHEALTHY"
  end

  test "an old completed sweep doesn't mask a newer one", %{conn: conn} do
    sweep_completed_at(DateTime.utc_now() |> DateTime.add(-3, :hour))
    sweep_completed_at(DateTime.utc_now() |> DateTime.add(-30, :second))

    assert get(conn, ~p"/health").status == 200
  end

  test "only completed sweeps count — a queued one is not a heartbeat", %{conn: conn} do
    Repo.insert!(%Oban.Job{
      worker: inspect(SweepWorker),
      queue: "default",
      state: "available",
      args: %{},
      inserted_at: DateTime.utc_now(),
      scheduled_at: DateTime.utc_now()
    })

    assert get(conn, ~p"/health").status == 503
  end
end
