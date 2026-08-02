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

  # Which commit is actually serving. Reported on both the healthy and
  # unhealthy paths, since "is my deploy live?" is most worth answering
  # when something looks wrong.
  test "reports the build it was made from", %{conn: conn} do
    System.put_env("GIT_SHA", "abcdef1234567890")
    on_exit(fn -> System.delete_env("GIT_SHA") end)

    sweep_completed_at(DateTime.utc_now() |> DateTime.add(-60, :second))
    assert response(get(conn, ~p"/health"), 200) =~ "build abcdef12"
  end

  test "reports the build on the unhealthy path too", %{conn: conn} do
    System.put_env("GIT_SHA", "abcdef1234567890")
    on_exit(fn -> System.delete_env("GIT_SHA") end)

    assert response(get(conn, ~p"/health"), 503) =~ "build abcdef12"
  end

  test "says unknown when nothing baked a commit in", %{conn: conn} do
    System.delete_env("GIT_SHA")

    sweep_completed_at(DateTime.utc_now() |> DateTime.add(-60, :second))
    assert response(get(conn, ~p"/health"), 200) =~ "build unknown"
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
