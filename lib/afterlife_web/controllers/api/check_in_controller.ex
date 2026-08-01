defmodule AfterlifeWeb.Api.CheckInController do
  @moduledoc """
  Lets other tools/scripts indicate activity programmatically — a
  smart-home presence check, a phone/laptop usage monitor, a cron job,
  whatever the owner wants to wire up — as an alternative to clicking
  the emailed magic link. Authenticated by a long-lived, per-switch
  token (`Switches.regenerate_api_token/1`), not a login session, so a
  plain `curl`/cron job can hit it.
  """

  use AfterlifeWeb, :controller

  alias Afterlife.Switches
  alias AfterlifeWeb.ClientIP

  def check_in(conn, %{"token" => token}) do
    case Switches.check_in_via_api(token, ClientIP.from(conn)) do
      {:ok, switch} ->
        json(conn, %{
          status: "ok",
          switch: switch.name,
          next_check_in_due: switch.next_due_at
        })

      {:error, :invalid_token} ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", message: "invalid or unknown token"})
    end
  end
end
