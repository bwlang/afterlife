defmodule AfterlifeWeb.MessageLive.NewTest do
  use AfterlifeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Afterlife.AccountsFixtures
  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches

  test "redirects if the user isn't logged in", %{conn: conn} do
    switch = switch_fixture()
    assert {:error, redirect} = live(conn, ~p"/switches/#{switch}/messages/new")
    assert {:redirect, %{to: path}} = redirect
    assert path == ~p"/users/log-in"
  end

  describe "new message" do
    # The date and age inputs only render once that mode is chosen, so
    # tests take the same two steps a person does.
    defp choose_mode(lv, mode) do
      lv |> form("#message-form", %{"schedule" => %{"mode" => mode}}) |> render_change()
      lv
    end

    setup %{conn: conn} do
      user = user_fixture()
      switch = switch_fixture(%{user: user})
      %{conn: log_in_user(conn, user), user: user, switch: switch}
    end

    test "raises for a switch belonging to another user", %{conn: conn} do
      someone_elses = switch_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/switches/#{someone_elses}/messages/new")
      end
    end

    test "addresses a message to the recipients picked", %{conn: conn, switch: switch} do
      jamie = recipient_fixture(switch, %{name: "Jamie", email: "jamie@example.com"})
      alex = recipient_fixture(switch, %{name: "Alex", email: "alex@example.com"})
      _unpicked = recipient_fixture(switch, %{name: "Sam", email: "sam@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      {:ok, _lv, html} =
        lv
        |> form("#message-form", %{
          "message" => %{"subject" => "For you", "body" => "I love you all."},
          "recipient_ids" => [to_string(jamie.id), to_string(alex.id)]
        })
        |> render_submit()
        |> follow_redirect(conn, ~p"/switches/#{switch}")

      assert html =~ "Message saved."

      assert [message] = Switches.list_messages(switch)
      emails = message.recipients |> Enum.map(& &1.email) |> Enum.sort()
      assert emails == ["alex@example.com", "jamie@example.com"]
    end

    test "refuses to save without at least one recipient", %{conn: conn, switch: switch} do
      recipient_fixture(switch)
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      html =
        lv
        |> form("#message-form", %{
          "message" => %{"subject" => "For you", "body" => "I love you all."}
        })
        |> render_submit()

      assert html =~ "Choose at least one recipient."
      assert Switches.list_messages(switch) == []
    end

    # The age is resolved to a date here, in the UI; nothing below the
    # context ever sees an age or a birthday.
    test "an age is stored as the date that recipient reaches it", %{conn: conn, switch: switch} do
      jamie = recipient_fixture(switch, %{birthdate: ~D[2020-03-14]})
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      lv
      |> choose_mode("age")
      |> form("#message-form", %{
        "message" => %{"subject" => "18th", "body" => "Happy birthday."},
        "schedule" => %{"mode" => "age", "age" => "18"},
        "recipient_ids" => [to_string(jamie.id)]
      })
      |> render_submit()

      assert [message] = Switches.list_messages(switch)
      assert [{recipient, due}] = message.schedule
      assert recipient.id == jamie.id
      assert due == ~U[2038-03-14 09:00:00Z]
    end

    test "a fixed date applies to everyone on the message", %{conn: conn, switch: switch} do
      a = recipient_fixture(switch, %{name: "A"})
      b = recipient_fixture(switch, %{name: "B", birthdate: ~D[2020-03-14]})

      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      lv
      |> choose_mode("date")
      |> form("#message-form", %{
        "message" => %{"subject" => "s", "body" => "b"},
        "schedule" => %{"mode" => "date", "date" => "2030-01-01"},
        "recipient_ids" => [to_string(a.id), to_string(b.id)]
      })
      |> render_submit()

      assert [message] = Switches.list_messages(switch)
      dues = message.schedule |> Enum.map(fn {_r, due} -> due end) |> Enum.uniq()
      assert dues == [~U[2030-01-01 09:00:00Z]]
    end

    # The age field hides the wait: the same age is five years for one
    # recipient and eighteen for another, and that difference decides
    # whether the message is plausible or a wish.
    test "shows how far off each held copy would land", %{conn: conn, switch: switch} do
      baby = recipient_fixture(switch, %{name: "Robin", birthdate: ~D[2025-03-14]})
      teen = recipient_fixture(switch, %{name: "Jamie", birthdate: ~D[2013-03-14]})

      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      html =
        lv
        |> choose_mode("age")
        |> form("#message-form", %{
          "message" => %{"subject" => "s", "body" => "b"},
          "schedule" => %{"mode" => "age", "age" => "18"},
          "recipient_ids" => [to_string(baby.id), to_string(teen.id)]
        })
        |> render_change()

      assert html =~ "Robin: 14 March 2043"
      assert html =~ "Jamie: 14 March 2031"
    end

    test "says so when a held copy would go out immediately anyway", %{
      conn: conn,
      switch: switch
    } do
      grown = recipient_fixture(switch, %{name: "Alex", birthdate: ~D[1980-03-14]})
      unknown = recipient_fixture(switch, %{name: "Sam"})

      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      html =
        lv
        |> choose_mode("age")
        |> form("#message-form", %{
          "message" => %{"subject" => "s", "body" => "b"},
          "schedule" => %{"mode" => "age", "age" => "18"},
          "recipient_ids" => [to_string(grown.id), to_string(unknown.id)]
        })
        |> render_change()

      assert html =~ "Alex: as soon as the switch triggers"
      assert html =~ "Sam: no birthday recorded"
    end

    test "attaches an uploaded file to the message", %{conn: conn, switch: switch} do
      jamie = recipient_fixture(switch)
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      attachment =
        file_input(lv, "#message-form", :attachments, [
          %{name: "note.txt", content: "a little note for later", type: "text/plain"}
        ])

      assert render_upload(attachment, "note.txt") =~ "note.txt"

      lv
      |> form("#message-form", %{
        "message" => %{"subject" => "For you", "body" => "I love you all."},
        "recipient_ids" => [to_string(jamie.id)]
      })
      |> render_submit()

      assert [message] = Switches.list_messages(switch)
      assert [attachment] = message.attachments
      assert attachment.filename == "note.txt"
    end
  end
end
