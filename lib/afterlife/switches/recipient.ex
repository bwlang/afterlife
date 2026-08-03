defmodule Afterlife.Switches.Recipient do
  @moduledoc """
  Someone who receives messages from a switch.

  Scoped to the switch rather than to a single message, so a person is
  entered once and reused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "recipients" do
    field :name, :string
    field :email, :string
    field :phone, :string

    # Optional, and only meaningful for messages held until a given date.
    field :birthdate, :date

    belongs_to :switch, Afterlife.Switches.Switch

    has_many :message_recipients, Afterlife.Switches.MessageRecipient
    has_many :messages, through: [:message_recipients, :message]

    timestamps(type: :utc_datetime)
  end

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:name, :email, :phone, :birthdate, :switch_id])
    |> validate_required([:name, :email, :switch_id])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_birthdate_in_past()
    |> foreign_key_constraint(:switch_id)
  end

  # A birthdate in the future would make every age-based delivery date
  # wrong, and silently: the message would just sit pending forever.
  defp validate_birthdate_in_past(changeset) do
    case get_field(changeset, :birthdate) do
      nil ->
        changeset

      date ->
        if Date.after?(date, Date.utc_today()) do
          add_error(changeset, :birthdate, "can't be in the future")
        else
          changeset
        end
    end
  end
end
