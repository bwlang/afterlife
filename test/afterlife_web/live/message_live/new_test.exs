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

    test "creates a message with recipients, parsing name <email> and bare emails", %{
      conn: conn,
      switch: switch
    } do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      {:ok, _lv, html} =
        lv
        |> form("#message-form", %{
          "message" => %{"subject" => "For you", "body" => "I love you all."},
          "recipients" => "Jamie <jamie@example.com>\nalex@example.com"
        })
        |> render_submit()
        |> follow_redirect(conn, ~p"/switches/#{switch}")

      assert html =~ "Message saved."

      assert [message] = Switches.list_messages(switch)
      assert message.subject == "For you"

      emails = message.recipients |> Enum.map(& &1.email) |> Enum.sort()
      assert emails == ["alex@example.com", "jamie@example.com"]
      assert Enum.find(message.recipients, &(&1.email == "jamie@example.com")).name == "Jamie"
    end

    test "refuses to save without at least one recipient", %{conn: conn, switch: switch} do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      html =
        lv
        |> form("#message-form", %{
          "message" => %{"subject" => "For you", "body" => "I love you all."},
          "recipients" => ""
        })
        |> render_submit()

      assert html =~ "Add at least one recipient."
      assert Switches.list_messages(switch) == []
    end

    test "attaches an uploaded file to the message", %{conn: conn, switch: switch} do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      attachment =
        file_input(lv, "#message-form", :attachments, [
          %{
            name: "note.txt",
            content: "a little note for later",
            type: "text/plain"
          }
        ])

      assert render_upload(attachment, "note.txt") =~ "note.txt"

      {:ok, _lv, _html} =
        lv
        |> form("#message-form", %{
          "message" => %{"subject" => "For you", "body" => "I love you all."},
          "recipients" => "jamie@example.com"
        })
        |> render_submit()
        |> follow_redirect(conn, ~p"/switches/#{switch}")

      assert [message] = Switches.list_messages(switch)
      assert [attachment] = message.attachments
      assert attachment.filename == "note.txt"

      # Contents are loaded only on the delivery path — the dashboard
      # listing deliberately carries metadata alone.
      assert [recipient] = message.recipients
      {message, _recipient} = Switches.get_message_with_recipient!(message.id, recipient.id)
      assert [%{content: "a little note for later"}] = message.attachments
    end

    test "reports an unparseable recipient instead of silently dropping it", %{
      conn: conn,
      switch: switch
    } do
      {:ok, lv, _html} = live(conn, ~p"/switches/#{switch}/messages/new")

      html =
        lv
        |> form("#message-form", %{
          "message" => %{"subject" => "For you", "body" => "I love you all."},
          "recipients" => "jamie@example.com\nnot-an-email"
        })
        |> render_submit()

      assert html =~ "Check the recipients:"
      assert Switches.list_messages(switch) == []
    end
  end
end
