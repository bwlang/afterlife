defmodule Afterlife.Switches.MessageRecipient do
  @moduledoc """
  One person's copy of one message, and when it is due.

  `deliver_on` is a plain date — nil for "as soon as the switch
  triggers". Whatever produced that date (a fixed anniversary, the
  birthday someone turns 18 on) is an input-layer concern; nothing
  downstream of here knows about ages or birthdays.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "message_recipients" do
    field :deliver_on, :date

    belongs_to :message, Afterlife.Switches.Message
    belongs_to :recipient, Afterlife.Switches.Recipient
  end

  def changeset(message_recipient, attrs) do
    message_recipient
    |> cast(attrs, [:message_id, :recipient_id, :deliver_on])
    |> validate_required([:recipient_id])
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:recipient_id)
    |> unique_constraint([:message_id, :recipient_id])
  end
end
