defmodule Afterlife.Switches.DeliveryWorker do
  @moduledoc """
  Delivers one message to one recipient. Enqueued by
  `Afterlife.Switches.enqueue_delivery/1` when a switch triggers;
  unique on its args so re-enqueueing the same (message, recipient)
  pair is a no-op, and Oban's own retry/backoff handles transient
  send failures.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 5, unique: [fields: [:args], period: :infinity]

  alias Afterlife.Switches
  alias Afterlife.Switches.Notifier

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id, "recipient_id" => recipient_id}}) do
    {message, recipient} = Switches.get_message_with_recipient!(message_id, recipient_id)
    {:ok, log} = Switches.get_or_create_delivery_log(message_id, recipient_id)

    case Notifier.deliver_final_message(message, recipient) do
      {:ok, _email} ->
        Switches.mark_delivery_sent(log)
        :ok

      {:error, reason} ->
        Switches.mark_delivery_failed(log, reason)
        {:error, reason}
    end
  end
end
