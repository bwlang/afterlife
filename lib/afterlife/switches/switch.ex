defmodule Afterlife.Switches.Switch do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active grace paused triggered cancelled)

  schema "switches" do
    field :name, :string
    field :check_in_interval_days, :integer, default: 30
    field :grace_period_days, :integer, default: 7
    field :status, :string, default: "active"
    field :last_check_in_at, :utc_datetime
    field :next_due_at, :utc_datetime
    field :api_token_hash, :binary

    belongs_to :user, Afterlife.Accounts.User
    has_many :messages, Afterlife.Switches.Message
    has_many :trusted_contacts, Afterlife.Switches.TrustedContact
    has_many :check_in_events, Afterlife.Switches.CheckInEvent

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(switch, attrs) do
    switch
    |> cast(attrs, [
      :name,
      :check_in_interval_days,
      :grace_period_days,
      :status,
      :last_check_in_at,
      :next_due_at,
      :user_id
    ])
    |> validate_required([:name, :check_in_interval_days, :grace_period_days, :status])
    |> validate_number(:check_in_interval_days, greater_than: 0)
    |> validate_number(:grace_period_days, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
  end
end
