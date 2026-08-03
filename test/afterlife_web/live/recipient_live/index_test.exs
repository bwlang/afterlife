defmodule AfterlifeWeb.RecipientLive.IndexTest do
  use AfterlifeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Afterlife.AccountsFixtures
  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches

  test "redirects if the user isn't logged in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/recipients")
  end

  describe "recipients page" do
    setup %{conn: conn} do
      user = user_fixture()
      switch = switch_fixture(%{user: user, name: "Letters"})
      %{conn: log_in_user(conn, user), user: user, switch: switch}
    end

    test "lists everyone across the account's switches", %{conn: conn, switch: switch} do
      recipient_fixture(switch, %{name: "Robin", email: "robin@example.com"})

      other = switch_fixture(%{user: get_owner(switch), name: "Second switch"})
      recipient_fixture(other, %{name: "Sam", email: "sam@example.com"})

      {:ok, _lv, html} = live(conn, ~p"/recipients")

      assert html =~ "Robin"
      assert html =~ "Sam"
      assert html =~ "Letters"
      assert html =~ "Second switch"
    end

    test "updates a birthday, which every message then uses", %{conn: conn, switch: switch} do
      robin = recipient_fixture(switch, %{name: "Robin", birthdate: ~D[2020-01-01]})

      {:ok, lv, _html} = live(conn, ~p"/recipients")

      html =
        lv
        |> form("#recipient-#{robin.id}", %{
          "recipient" => %{
            "name" => "Robin",
            "email" => robin.email,
            "birthdate" => "2025-03-14"
          }
        })
        |> render_submit()

      assert html =~ "Recipient updated."
      assert Switches.get_recipient!(switch, robin.id).birthdate == ~D[2025-03-14]
    end

    test "shows validation errors rather than silently discarding them", %{
      conn: conn,
      switch: switch
    } do
      robin = recipient_fixture(switch, %{name: "Robin"})

      {:ok, lv, _html} = live(conn, ~p"/recipients")

      html =
        lv
        |> form("#recipient-#{robin.id}", %{
          "recipient" => %{"name" => "Robin", "email" => "not-an-email"}
        })
        |> render_submit()

      assert html =~ "must have the @ sign"
      assert Switches.get_recipient!(switch, robin.id).email == robin.email
    end

    test "removes a recipient", %{conn: conn, switch: switch} do
      robin = recipient_fixture(switch, %{name: "Robin"})

      {:ok, lv, _html} = live(conn, ~p"/recipients")
      html = lv |> element("a", "Remove") |> render_click()

      assert html =~ "Recipient removed."
      assert Switches.list_recipients(switch) == []
      refute html =~ "Robin"
      _ = robin
    end

    # Recipients are reached through their switch's owner, so an id from
    # someone else's account resolves to nothing rather than to their
    # family's contact details.
    test "can't touch another account's recipients", %{conn: conn} do
      stranger = recipient_fixture(switch_fixture(), %{name: "Stranger"})

      {:ok, lv, html} = live(conn, ~p"/recipients")
      refute html =~ "Stranger"

      # The scoped lookup finds nothing and the view crashes rather than
      # serving someone else's data. Trapping exits because the crash
      # arrives from the linked LiveView process.
      Process.flag(:trap_exit, true)
      assert catch_exit(render_click(lv, "delete", %{"id" => to_string(stranger.id)}))
    end
  end

  defp get_owner(switch), do: Afterlife.Accounts.get_user!(switch.user_id)
end
