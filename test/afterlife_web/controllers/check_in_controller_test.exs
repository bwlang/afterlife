defmodule AfterlifeWeb.CheckInControllerTest do
  use AfterlifeWeb.ConnCase

  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches

  describe "GET /check-in/:token" do
    test "checks in and confirms, for a valid token", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token} = Switches.generate_check_in_token(switch)

      conn = get(conn, ~p"/check-in/#{raw_token}")

      assert response(conn, 200) =~ switch.name
      assert response(conn, 200) =~ "checked in"
    end

    test "404s for an invalid or expired token", %{conn: conn} do
      conn = get(conn, ~p"/check-in/not-a-real-token")

      assert response(conn, 404) =~ "invalid or has expired"
    end

    test "a token can't be reused", %{conn: conn} do
      switch = switch_fixture()
      {:ok, raw_token} = Switches.generate_check_in_token(switch)

      conn |> get(~p"/check-in/#{raw_token}") |> response(200)

      conn = get(build_conn(), ~p"/check-in/#{raw_token}")
      assert response(conn, 404)
    end
  end
end
