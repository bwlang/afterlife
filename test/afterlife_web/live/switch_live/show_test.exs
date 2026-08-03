defmodule AfterlifeWeb.SwitchLive.ShowTest do
  use AfterlifeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Afterlife.AccountsFixtures
  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches

  test "redirects if the user isn't logged in", %{conn: conn} do
    switch = switch_fixture()
    assert {:error, redirect} = live(conn, ~p"/switches/#{switch}")
    assert {:redirect, %{to: path}} = redirect
    assert path == ~p"/users/log-in"
  end

  describe "show" do
    setup %{conn: conn} do
      user = user_fixture()
      switch = switch_fixture(%{user: user, name: "Letters to my family"})
      %{conn: log_in_user(conn, user), user: user, switch: switch}
    end

    test "shows the switch's name, status, and due date", %{conn: conn, switch: switch} do
      {:ok, _lv, html} = live(conn, ~p"/switches/#{switch}")

      assert html =~ "Letters to my family"
      assert html =~ "active"
    end

    test "raises for a switch belonging to another user", %{conn: conn} do
      someone_elses = switch_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/switches/#{someone_elses}")
      end
    end

    test "checks in via the button", %{conn: conn, switch: switch} do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}")

      html = render_click(lv, "check_in")

      assert html =~ "Checked in."
      assert ["manual_checkin"] = Switches.list_check_in_events(switch) |> Enum.map(& &1.type)
    end

    test "pauses and then resumes", %{conn: conn, switch: switch} do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}")

      html = render_click(lv, "pause")
      assert html =~ "Switch paused."
      assert html =~ "paused"

      html = render_click(lv, "resume")
      assert html =~ "Switch resumed."
      assert html =~ "active"
    end

    test "updates settings", %{conn: conn, switch: switch} do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}")

      html =
        lv
        |> form("#settings-form", %{
          "switch" => %{
            "name" => "New name",
            "check_in_interval_days" => "10",
            "grace_period_days" => "3"
          }
        })
        |> render_submit()

      assert html =~ "Settings saved."
      assert html =~ "New name"
      assert Switches.get_switch!(get_owner(switch), switch.id).check_in_interval_days == 10
    end

    test "generates a one-time-shown API check-in URL", %{conn: conn, switch: switch} do
      {:ok, lv, html} = live(conn, ~p"/switches/#{switch}")
      refute html =~ "check_in/"

      html = render_click(lv, "regenerate_api_token")

      assert html =~ "/api/check_in/"
      assert html =~ "won&#39;t be shown again"
    end

    test "lists messages and their recipients", %{conn: conn, switch: switch} do
      {message, recipient} =
        message_with_recipient(switch, %{subject: "For you, whenever"}, %{
          email: "jamie@example.com"
        })

      _ = message

      {:ok, _lv, html} = live(conn, ~p"/switches/#{switch}")

      assert html =~ "For you, whenever"
      assert html =~ recipient.email
    end

    test "shows the date a held message would actually be sent", %{conn: conn, switch: switch} do
      message_with_recipient(switch, %{deliver_on: ~D[2043-03-14]}, %{name: "Robin"})

      {:ok, _lv, html} = live(conn, ~p"/switches/#{switch}")

      assert html =~ "Robin: 14 March 2043"
    end

    test "links to the new-message page", %{conn: conn, switch: switch} do
      {:ok, _lv, html} = live(conn, ~p"/switches/#{switch}")
      assert html =~ ~p"/switches/#{switch}/messages/new"
    end

    test "shows where a check-in came from in the activity log", %{conn: conn, switch: switch} do
      {:ok, raw_token, switch} = Switches.regenerate_api_token(switch)
      {:ok, _switch} = Switches.check_in_via_api(raw_token, "203.0.113.7")

      {:ok, _lv, html} = live(conn, ~p"/switches/#{switch}")

      assert html =~ "api_check_in"
      assert html =~ "203.0.113.7"
    end
  end

  defp get_owner(switch), do: Afterlife.Accounts.get_user!(switch.user_id)
end
