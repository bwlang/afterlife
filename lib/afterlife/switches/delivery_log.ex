defmodule Afterlife.Switches.DeliveryLog do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending sent failed)

  schema "delivery_logs" do
    field :channel, :string, default: "email"
    field :status, :string, default: "pending"
    field :sent_at, :utc_datetime
    # When this becomes due; nil means immediately. This is the durable
    # schedule — an age-based delivery can be decades out.
    field :deliver_after, :utc_datetime
    field :error, :string

    belongs_to :message, Afterlife.Switches.Message
    belongs_to :recipient, Afterlife.Switches.Recipient

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :channel,
      :status,
      :sent_at,
      :error,
      :deliver_after,
      :message_id,
      :recipient_id
    ])
    |> validate_required([:message_id, :recipient_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:recipient_id)
  end
end
