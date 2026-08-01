defmodule AfterlifeWeb.SwitchLive.IndexTest do
  use AfterlifeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Afterlife.AccountsFixtures
  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches

  test "redirects if the user isn't logged in", %{conn: conn} do
    assert {:error, redirect} = live(conn, ~p"/switches")
    assert {:redirect, %{to: path}} = redirect
    assert path == ~p"/users/log-in"
  end

  describe "index" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "shows an empty state with no switches", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/switches")
      assert html =~ "No switches yet."
    end

    test "lists only the current user's switches", %{conn: conn, user: user} do
      mine = switch_fixture(%{user: user, name: "My family letters"})
      _someone_elses = switch_fixture(%{name: "Not mine"})

      {:ok, _lv, html} = live(conn, ~p"/switches")

      assert html =~ mine.name
      refute html =~ "Not mine"
    end

    test "creates a new switch", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/switches/new")

      {:ok, _lv, html} =
        lv
        |> form("#switch-form", %{
          "switch" => %{
            "name" => "Letters to my family",
            "check_in_interval_days" => "30",
            "grace_period_days" => "7"
          }
        })
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Switch created."
      assert [switch] = Switches.list_switches(user)
      assert switch.name == "Letters to my family"
    end

    test "shows validation errors for a blank name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/switches/new")

      html =
        lv
        |> form("#switch-form", %{"switch" => %{"name" => ""}})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end
  end
end
