defmodule Afterlife.Repo.Migrations.CreateSwitchDomain do
  use Ecto.Migration

  def change do
    create table(:switches) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :check_in_interval_days, :integer, null: false, default: 30
      add :grace_period_days, :integer, null: false, default: 7
      add :status, :string, null: false, default: "active"
      add :last_check_in_at, :utc_datetime
      add :next_due_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:switches, [:user_id])
    create index(:switches, [:status, :next_due_at])

    create table(:messages) do
      add :switch_id, references(:switches, on_delete: :delete_all), null: false
      add :subject, :binary, null: false
      add :body, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:switch_id])

    create table(:recipients) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string

      timestamps(type: :utc_datetime)
    end

    create index(:recipients, [:message_id])

    create table(:attachments) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :content, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:attachments, [:message_id])

    create table(:trusted_contacts) do
      add :switch_id, references(:switches, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string
      add :relationship, :string

      timestamps(type: :utc_datetime)
    end

    create index(:trusted_contacts, [:switch_id])

    # Append-only audit log. Not updated after insert, so no updated_at.
    create table(:check_in_events) do
      add :switch_id, references(:switches, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :channel, :string, null: false
      add :actor_type, :string
      add :actor_id, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:check_in_events, [:switch_id])

    create table(:action_tokens) do
      add :switch_id, references(:switches, on_delete: :delete_all), null: false

      add :trusted_contact_id,
          references(:trusted_contacts, on_delete: :delete_all)

      add :purpose, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:action_tokens, [:token_hash])
    create index(:action_tokens, [:switch_id])

    create table(:delivery_logs) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :recipient_id, references(:recipients, on_delete: :delete_all), null: false
      add :channel, :string, null: false, default: "email"
      add :status, :string, null: false, default: "pending"
      add :sent_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:delivery_logs, [:message_id])
    create index(:delivery_logs, [:recipient_id])
  end
end
