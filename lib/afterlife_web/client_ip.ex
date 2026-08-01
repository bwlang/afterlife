defmodule AfterlifeWeb.ClientIP do
  @moduledoc """
  The address a request actually came from.

  `conn.remote_ip` is the proxy in production — every check-in would be
  recorded as 127.0.0.1 — so the real address has to come from a header
  nginx sets.

  Deliberately `x-real-ip` and not `x-forwarded-for`: our nginx uses
  `$proxy_add_x_forwarded_for`, which *appends* to whatever the client
  sent, so a caller can prepend any address it likes to that header.
  `x-real-ip` is set from `$remote_addr` and overwritten on every
  request, so it can't be spoofed from outside. This is only safe
  because the app listens on loopback and nginx is the only way in.
  """

  def from(conn) do
    case Plug.Conn.get_req_header(conn, "x-real-ip") do
      [address | _] -> String.slice(address, 0, 45)
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
