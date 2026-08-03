defmodule Afterlife.Switches.DeliveryWorkerTest do
  use Afterlife.DataCase

  import Swoosh.TestAssertions
  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches.{DeliveryLog, DeliveryWorker}

  defmodule FailingAdapter do
    @moduledoc false
    use Swoosh.Adapter, required_config: []

    def deliver(_email, _config), do: {:error, "simulated failure"}
    def deliver_many(_emails, _config), do: {:error, "simulated failure"}
  end

  describe "perform/1" do
    test "delivers the message, marks the delivery log sent" do
      switch = switch_fixture()
      {message, recipient} = message_with_recipient(switch)
      flush_mailbox()

      job = %Oban.Job{args: %{"message_id" => message.id, "recipient_id" => recipient.id}}
      assert :ok = DeliveryWorker.perform(job)

      assert_email_sent(to: recipient.email, subject: message.subject)

      assert %DeliveryLog{status: "sent", sent_at: %DateTime{}} =
               Repo.get_by!(DeliveryLog, message_id: message.id, recipient_id: recipient.id)
    end

    test "is safe to run twice for the same (message, recipient) pair" do
      switch = switch_fixture()
      {message, recipient} = message_with_recipient(switch)

      job = %Oban.Job{args: %{"message_id" => message.id, "recipient_id" => recipient.id}}
      assert :ok = DeliveryWorker.perform(job)
      assert :ok = DeliveryWorker.perform(job)

      assert [%DeliveryLog{status: "sent"}] =
               Repo.all(
                 from(d in DeliveryLog,
                   where: d.message_id == ^message.id and d.recipient_id == ^recipient.id
                 )
               )
    end

    test "marks the delivery log failed when sending errors" do
      switch = switch_fixture()
      {message, recipient} = message_with_recipient(switch)

      original_config = Application.get_env(:afterlife, Afterlife.Mailer)
      Application.put_env(:afterlife, Afterlife.Mailer, adapter: FailingAdapter)
      on_exit(fn -> Application.put_env(:afterlife, Afterlife.Mailer, original_config) end)

      job = %Oban.Job{args: %{"message_id" => message.id, "recipient_id" => recipient.id}}
      assert {:error, "simulated failure"} = DeliveryWorker.perform(job)

      assert %DeliveryLog{status: "failed", error: error} =
               Repo.get_by!(DeliveryLog, message_id: message.id, recipient_id: recipient.id)

      assert error =~ "simulated failure"
    end
  end
end
