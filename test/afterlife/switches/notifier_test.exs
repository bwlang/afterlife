defmodule Afterlife.Switches.NotifierTest do
  use Afterlife.DataCase

  import Swoosh.TestAssertions
  import Afterlife.SwitchesFixtures

  alias Afterlife.Accounts
  alias Afterlife.Switches
  alias Afterlife.Switches.Notifier
  alias Swoosh.Email.Recipient

  describe "deliver_reminder/3" do
    test "reminds an active switch's owner, with the check-in link" do
      switch = switch_fixture(%{check_in_interval_days: 3})
      owner = Accounts.get_user!(switch.user_id)
      flush_mailbox()

      assert {:ok, _email} =
               Notifier.deliver_reminder(owner, switch, "http://example.com/check-in/abc")

      assert_email_sent(
        to: owner.email,
        subject: ~r/^Check in on "#{switch.name}"/,
        text_body: ~r{http://example.com/check-in/abc}
      )
    end

    test "escalates to an urgent tone once the switch is in its grace period" do
      switch = switch_fixture()
      switch = switch |> Ecto.Changeset.change(status: "grace") |> Repo.update!()
      owner = Accounts.get_user!(switch.user_id)
      flush_mailbox()

      assert {:ok, _email} =
               Notifier.deliver_reminder(owner, switch, "http://example.com/check-in/abc")

      assert_email_sent(subject: ~r/^URGENT: /, text_body: ~r/You missed your last check-in/)
    end
  end

  describe "deliver_final_message/2" do
    test "sends the message body and attachments to the recipient" do
      switch = switch_fixture()

      {message, recipient} =
        message_with_recipient(
          switch,
          %{subject: "For you", body: "I love you all."},
          %{name: "Jamie", email: "jamie@example.com"}
        )

      {:ok, _attachment} =
        Switches.add_attachment(message, %{
          filename: "note.txt",
          content_type: "text/plain",
          byte_size: 5,
          content: "hello"
        })

      {message, recipient} = Switches.get_message_with_recipient!(message.id, recipient.id)
      flush_mailbox()

      assert {:ok, _email} = Notifier.deliver_final_message(message, recipient)

      assert_email_sent(fn email ->
        email.subject == "For you" and
          email.text_body == "I love you all." and
          Recipient.format(recipient.email) in email.to and
          length(email.attachments) == 1
      end)
    end
  end
end
