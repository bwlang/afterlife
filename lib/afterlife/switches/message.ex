defmodule Afterlife.Switches.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :subject, Afterlife.Encrypted.Binary
    field :body, Afterlife.Encrypted.Binary

    belongs_to :switch, Afterlife.Switches.Switch
    has_many :recipients, Afterlife.Switches.Recipient
    has_many :attachments, Afterlife.Switches.Attachment

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:subject, :body, :switch_id])
    |> validate_required([:subject, :body])
    |> foreign_key_constraint(:switch_id)
  end
end
