defmodule Afterlife.Vault do
  @moduledoc """
  Encrypts message bodies and attachment contents at rest.

  Cipher/key configuration lives in config/{dev,test}.exs (fixed,
  non-secret keys) and config/runtime.exs (CLOAK_KEY env var in prod).
  """

  use Cloak.Vault, otp_app: :afterlife
end
