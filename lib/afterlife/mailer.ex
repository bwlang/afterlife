defmodule Afterlife.Mailer do
  @moduledoc """
  The app's Swoosh mailer, plus the one place every outgoing email is
  built — so the sender address is configured once
  (`config :afterlife, :email_from`) rather than repeated at each call
  site.
  """

  use Swoosh.Mailer, otp_app: :afterlife

  import Swoosh.Email

  @doc """
  Sends a plain-text email from the configured sender, optionally with
  a list of `Swoosh.Attachment`s. Returns `{:ok, email}` so callers can
  assert on what was sent.
  """
  def deliver_text(to, subject, body, attachments \\ []) do
    email =
      new()
      |> to(to)
      |> from(Application.fetch_env!(:afterlife, :email_from))
      |> subject(subject)
      |> text_body(body)
      |> then(&Enum.reduce(attachments, &1, fn file, email -> attachment(email, file) end))

    with {:ok, _metadata} <- deliver(email) do
      {:ok, email}
    end
  end
end
