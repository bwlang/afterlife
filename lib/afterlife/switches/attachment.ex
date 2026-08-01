defmodule Afterlife.Switches.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "attachments" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :content, Afterlife.Encrypted.Binary

    belongs_to :message, Afterlife.Switches.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :content_type, :byte_size, :content, :message_id])
    |> validate_required([:filename, :content_type, :byte_size, :content, :message_id])
    |> foreign_key_constraint(:message_id)
  end
end
