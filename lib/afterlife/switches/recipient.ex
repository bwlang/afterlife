defmodule Afterlife.Switches.Recipient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "recipients" do
    field :name, :string
    field :email, :string
    field :phone, :string

    belongs_to :message, Afterlife.Switches.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:name, :email, :phone, :message_id])
    |> validate_required([:name, :email, :message_id])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> foreign_key_constraint(:message_id)
  end
end
