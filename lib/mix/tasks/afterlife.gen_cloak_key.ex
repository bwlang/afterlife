defmodule Mix.Tasks.Afterlife.GenCloakKey do
  @shortdoc "Generates a random key for CLOAK_KEY (encryption at rest)"

  @moduledoc """
  Prints a random base64-encoded 256-bit key suitable for the CLOAK_KEY
  environment variable, which encrypts message bodies and attachments
  at rest in prod (see config/runtime.exs).

      $ mix afterlife.gen_cloak_key
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
    |> Mix.shell().info()
  end
end
