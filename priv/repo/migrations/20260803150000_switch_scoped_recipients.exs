defmodule Afterlife.Repo.Migrations.SwitchScopedRecipients do
  use Ecto.Migration

  @moduledoc """
  Recipients become people on a switch rather than rows on a message, so
  a birthday is recorded once per person instead of once per message
  they happen to appear in.
  """

  def up do
    alter table(:recipients) do
      add :switch_id, references(:switches, on_delete: :delete_all)
      add :birthdate, :date
    end

    create table(:message_recipients) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :recipient_id, references(:recipients, on_delete: :delete_all), null: false

      # When this person gets this message. nil means "as soon as the
      # switch triggers". Per link rather than per message because an
      # age resolves to a different date for each recipient — and the
      # delivery path deals only in dates, never in ages or birthdays.
      add :deliver_on, :date
    end

    create unique_index(:message_recipients, [:message_id, :recipient_id])

    alter table(:delivery_logs) do
      # When this delivery becomes due. nil means immediately. The
      # schedule lives here rather than in a job queue: these dates can
      # be decades out, far longer than any queue row should be trusted.
      add :deliver_after, :utc_datetime
    end

    flush()

    execute """
    UPDATE recipients
       SET switch_id = (SELECT m.switch_id FROM messages m WHERE m.id = recipients.message_id)
    """

    execute """
    INSERT INTO message_recipients (message_id, recipient_id)
    SELECT message_id, id FROM recipients
    """

    # Collapse anyone listed on more than one message of the same switch
    # onto their lowest-numbered row, then drop what's left unreferenced.
    execute """
    UPDATE message_recipients
       SET recipient_id = (
         SELECT MIN(r2.id)
           FROM recipients r1
           JOIN recipients r2
             ON r2.switch_id = r1.switch_id AND r2.email = r1.email
          WHERE r1.id = message_recipients.recipient_id
       )
    """

    execute """
    DELETE FROM recipients
     WHERE id NOT IN (SELECT recipient_id FROM message_recipients)
    """

    drop index(:recipients, [:message_id])

    alter table(:recipients) do
      remove :message_id
    end

    create index(:recipients, [:switch_id])
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: rolling back would have to guess which message each recipient belonged to"
  end
end
