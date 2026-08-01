defmodule AfterlifeWeb.CheckInController do
  @moduledoc """
  Consumes a reminder email's delay link. Deliberately unauthenticated
  (no login required to click it) — the security boundary is the
  hashed, one-time, expiring token itself (`Afterlife.Switches.ActionToken`).
  """

  use AfterlifeWeb, :controller

  alias Afterlife.Switches
  alias AfterlifeWeb.ClientIP

  def show(conn, %{"token" => token}) do
    case Switches.check_in_via_token(token, ClientIP.from(conn)) do
      {:ok, switch} ->
        text(conn, ~s(Thanks — "#{switch.name}" has been checked in. See you next time.))

      {:error, :invalid_or_expired} ->
        conn
        |> put_status(:not_found)
        |> text("This check-in link is invalid or has expired.")
    end
  end
end
