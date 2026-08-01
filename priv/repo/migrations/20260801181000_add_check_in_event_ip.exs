defmodule Afterlife.Repo.Migrations.AddCheckInEventIp do
  use Ecto.Migration

  def change do
    # Where a check-in came from. Mainly for the token-authenticated
    # paths: a token that can reset the switch is worth being able to
    # audit, and an unfamiliar address is the signal that one has
    # leaked.
    alter table(:check_in_events) do
      add :ip_address, :string
    end
  end
end
