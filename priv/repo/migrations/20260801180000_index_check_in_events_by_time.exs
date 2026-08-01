defmodule Afterlife.Repo.Migrations.IndexCheckInEventsByTime do
  use Ecto.Migration

  def change do
    # The dashboard reads the newest events for one switch. Automated
    # check-ins make this the fastest-growing table in the schema.
    create index(:check_in_events, [:switch_id, :inserted_at])
  end
end
