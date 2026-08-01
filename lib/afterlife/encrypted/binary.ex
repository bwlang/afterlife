defmodule Afterlife.Encrypted.Binary do
  @moduledoc """
  An Ecto type for fields that must be encrypted at rest: message
  subjects/bodies and attachment contents.
  """

  use Cloak.Ecto.Binary, vault: Afterlife.Vault
end
