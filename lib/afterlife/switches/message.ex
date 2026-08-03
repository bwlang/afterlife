defmodule Afterlife.Switches.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :subject, Afterlife.Encrypted.Binary
    field :body, Afterlife.Encrypted.Binary

    belongs_to :switch, Afterlife.Switches.Switch
    has_many :attachments, Afterlife.Switches.Attachment

    # Scheduling lives on the link, not here: each recipient can be due
    # on a different date.
    has_many :message_recipients, Afterlife.Switches.MessageRecipient, on_replace: :delete
    has_many :recipients, through: [:message_recipients, :recipient]

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:subject, :body, :switch_id])
    |> validate_required([:subject, :body])
    |> foreign_key_constraint(:switch_id)
  end
end
