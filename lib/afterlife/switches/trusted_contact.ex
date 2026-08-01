defmodule Afterlife.Switches.TrustedContact do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trusted_contacts" do
    field :name, :string
    field :email, :string
    field :phone, :string
    field :relationship, :string

    belongs_to :switch, Afterlife.Switches.Switch

    timestamps(type: :utc_datetime)
  end

  def changeset(trusted_contact, attrs) do
    trusted_contact
    |> cast(attrs, [:name, :email, :phone, :relationship, :switch_id])
    |> validate_required([:name, :email, :switch_id])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> foreign_key_constraint(:switch_id)
  end
end
