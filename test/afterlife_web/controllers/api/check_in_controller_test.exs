defmodule AfterlifeWeb.Api.CheckInControllerTest do
  use AfterlifeWeb.ConnCase

  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches

  describe "GET /api/check_in/:token" do
    test "checks in and returns the switch's new due date, for a valid token", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token, _switch} = Switches.regenerate_api_token(switch)

      conn = get(conn, ~p"/api/check_in/#{raw_token}")

      assert %{"status" => "ok", "switch" => name, "next_check_in_due" => due} =
               json_response(conn, 200)

      assert name == switch.name
      assert due
    end

    test "404s with a JSON error for an unknown token", %{conn: conn} do
      conn = get(conn, ~p"/api/check_in/nonexistent")

      assert %{"status" => "error"} = json_response(conn, 404)
    end

    test "records the caller's address from the proxy header", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token, _switch} = Switches.regenerate_api_token(switch)

      conn
      |> put_req_header("x-real-ip", "203.0.113.7")
      |> get(~p"/api/check_in/#{raw_token}")

      assert [%{type: "api_check_in", ip_address: "203.0.113.7"}] =
               Switches.list_check_in_events(switch)
    end

    # nginx appends to x-forwarded-for, so a caller can prepend whatever
    # it likes. Trusting it would let anyone forge the audit trail for a
    # token that can hold the switch open indefinitely.
    test "ignores a client-supplied x-forwarded-for", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token, _switch} = Switches.regenerate_api_token(switch)

      conn
      |> put_req_header("x-forwarded-for", "1.2.3.4")
      |> put_req_header("x-real-ip", "203.0.113.7")
      |> get(~p"/api/check_in/#{raw_token}")

      assert [%{ip_address: "203.0.113.7"}] = Switches.list_check_in_events(switch)
    end

    test "falls back to the peer address with no proxy header", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token, _switch} = Switches.regenerate_api_token(switch)

      get(conn, ~p"/api/check_in/#{raw_token}")

      assert [%{ip_address: "127.0.0.1"}] = Switches.list_check_in_events(switch)
    end
  end

  describe "POST /api/check_in/:token" do
    test "also accepts POST, for scripts that prefer it", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token, _switch} = Switches.regenerate_api_token(switch)

      conn = post(conn, ~p"/api/check_in/#{raw_token}")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
