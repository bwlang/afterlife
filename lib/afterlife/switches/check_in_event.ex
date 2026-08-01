defmodule Afterlife.Switches.CheckInEvent do
  @moduledoc """
  Append-only audit log: every reminder, check-in, vouch, and death
  confirmation for a switch. Never updated after insert.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(reminder_sent delay_clicked manual_checkin trusted_vouch trusted_confirm_death
            entered_grace triggered paused resumed api_check_in)
  @channels ~w(email dashboard system api)
  @actor_types ~w(user trusted_contact system)

  schema "check_in_events" do
    field :type, :string
    field :channel, :string
    field :actor_type, :string
    field :actor_id, :integer
    field :ip_address, :string

    belongs_to :switch, Afterlife.Switches.Switch

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :channel, :actor_type, :actor_id, :ip_address, :switch_id])
    |> validate_required([:type, :channel, :switch_id])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:actor_type, @actor_types)
    |> foreign_key_constraint(:switch_id)
  end
end
