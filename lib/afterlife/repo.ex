defmodule Afterlife.Repo do
  use Ecto.Repo,
    otp_app: :afterlife,
    adapter: Ecto.Adapters.SQLite3
end
