defmodule Afterlife.Switches.Notifier do
  @moduledoc """
  Builds and sends the check-in reminder and final-delivery emails.
  """

  alias Afterlife.Accounts.User
  alias Afterlife.Mailer
  alias Afterlife.Switches.{Message, Recipient, Switch}

  @doc """
  A check-in reminder for the switch's owner, with escalating urgency
  as the deadline nears and once the grace period has started.
  """
  def deliver_reminder(%User{} = owner, %Switch{} = switch, check_in_url) do
    {subject, urgency_line} = reminder_copy(switch)

    Mailer.deliver_text(owner.email, subject, """

    ==============================

    Hi,

    #{urgency_line}

    Vigil: #{switch.name}

    If you're fine, click below to reset the timer:

    #{check_in_url}

    If you don't recognize this vigil, something's wrong — check your account.

    ==============================
    """)
  end

  defp reminder_copy(%Switch{status: "grace"} = switch) do
    days_left = days_until(switch.next_due_at)

    {"URGENT: \"#{switch.name}\" will send your messages in #{days_left} day(s)",
     "You missed your last check-in. Your messages will be delivered automatically " <>
       "in #{days_left} day(s) unless you check in now."}
  end

  defp reminder_copy(%Switch{} = switch) do
    days_left = days_until(switch.next_due_at)

    {"Check in on \"#{switch.name}\" (#{days_left} day(s) left)",
     "Just a reminder to check in — you have #{days_left} day(s) left before the grace period starts."}
  end

  defp days_until(due_at) do
    due_at |> DateTime.diff(DateTime.utc_now(), :day) |> max(0)
  end

  @doc """
  The final message itself, delivered to one recipient with its
  attachments. Called once per (message, recipient) by `DeliveryWorker`.
  """
  def deliver_final_message(%Message{} = message, %Recipient{} = recipient) do
    attachments =
      Enum.map(message.attachments, fn attachment ->
        Swoosh.Attachment.new({:data, attachment.content},
          filename: attachment.filename,
          content_type: attachment.content_type
        )
      end)

    Mailer.deliver_text(recipient.email, message.subject, message.body, attachments)
  end
end
