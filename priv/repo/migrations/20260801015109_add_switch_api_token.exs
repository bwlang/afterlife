defmodule Afterlife.Repo.Migrations.AddSwitchApiToken do
  use Ecto.Migration

  def change do
    alter table(:switches) do
      add :api_token_hash, :binary
    end

    create unique_index(:switches, [:api_token_hash])
  end
end
