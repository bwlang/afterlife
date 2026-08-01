defmodule Afterlife.Switches.ActionToken do
  @moduledoc """
  A hashed, one-time, expiring token backing a magic link: check-in
  (owner), vouch, or confirm-death (trusted contact). Stored hashed
  (never the raw token) so a DB leak alone can't be used to act on a
  switch, and `used_at` lets us revoke/log usage the way a bare
  `Phoenix.Token` can't.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Afterlife.Repo
  alias Afterlife.Switches.ActionToken

  @purposes ~w(check_in vouch confirm_death)
  @hash_algorithm :sha256
  @rand_size 32
  @default_validity_in_days 45

  schema "action_tokens" do
    field :purpose, :string
    field :token_hash, :binary
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :switch, Afterlife.Switches.Switch
    belongs_to :trusted_contact, Afterlife.Switches.TrustedContact

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def purposes, do: @purposes

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:purpose, :token_hash, :expires_at, :used_at, :switch_id, :trusted_contact_id])
    |> validate_required([:purpose, :token_hash, :expires_at, :switch_id])
    |> validate_inclusion(:purpose, @purposes)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:switch_id)
    |> foreign_key_constraint(:trusted_contact_id)
  end

  @doc """
  Generates a new token for `purpose` on `switch`, inserts its hash,
  and returns `{:ok, raw_token}` — a URL-safe string to embed in a
  link. The raw token is never stored; only its SHA-256 hash is.
  """
  def generate(switch, purpose, opts \\ []) when purpose in @purposes do
    raw_token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, raw_token)

    valid_for_days = Keyword.get(opts, :valid_for_days, @default_validity_in_days)

    attrs = %{
      purpose: purpose,
      token_hash: hashed_token,
      switch_id: switch.id,
      trusted_contact_id: Keyword.get(opts, :trusted_contact_id),
      expires_at: DateTime.add(DateTime.utc_now(:second), valid_for_days, :day)
    }

    case %ActionToken{} |> changeset(attrs) |> Repo.insert() do
      {:ok, _token} -> {:ok, Base.url_encode64(raw_token, padding: false)}
      error -> error
    end
  end

  @doc """
  Atomically verifies and consumes a raw token for `purpose`: valid,
  unexpired, unused tokens are marked used in the same query that
  checks them, so a token can never be raced into double use.

  Returns `{:ok, action_token}` (preloaded with :switch and
  :trusted_contact) or `{:error, :invalid_or_expired}`.
  """
  def verify_and_consume(raw_token, purpose) when purpose in @purposes do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} -> consume(decoded, purpose)
      :error -> {:error, :invalid_or_expired}
    end
  end

  defp consume(decoded_token, purpose) do
    hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
    now = DateTime.utc_now(:second)

    query =
      from t in ActionToken,
        where:
          t.token_hash == ^hashed_token and t.purpose == ^purpose and is_nil(t.used_at) and
            t.expires_at > ^now

    case Repo.update_all(query, set: [used_at: now]) do
      {1, _} ->
        token =
          Repo.one!(
            from t in ActionToken,
              where: t.token_hash == ^hashed_token,
              preload: [:switch, :trusted_contact]
          )

        {:ok, token}

      {0, _} ->
        {:error, :invalid_or_expired}
    end
  end
end
