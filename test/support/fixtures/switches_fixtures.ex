defmodule Afterlife.SwitchesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Afterlife.Switches` context.
  """

  alias Afterlife.Switches

  import Afterlife.AccountsFixtures

  def valid_switch_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Test switch #{System.unique_integer()}",
      check_in_interval_days: 30,
      grace_period_days: 7
    })
  end

  def switch_fixture(attrs \\ %{}) do
    {user, attrs} = Map.pop(attrs, :user)
    user = user || user_fixture()

    {:ok, switch} = Switches.create_switch(user, valid_switch_attributes(attrs))
    switch
  end

  def message_fixture(switch, attrs \\ %{}) do
    {:ok, message} =
      Switches.create_message(
        switch,
        Enum.into(attrs, %{subject: "For you", body: "I love you all."})
      )

    message
  end

  def recipient_fixture(message, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{name: "Jamie", email: "jamie#{System.unique_integer()}@example.com"})

    {:ok, recipient} = Switches.add_recipient(message, attrs.name, attrs.email)
    recipient
  end

  @doc "Backdates a switch's next_due_at, bypassing the state machine, to simulate time passing."
  def backdate!(switch, seconds_ago) do
    due = DateTime.add(DateTime.utc_now(:second), -seconds_ago, :second)
    {:ok, switch} = switch |> Ecto.Changeset.change(next_due_at: due) |> Afterlife.Repo.update()
    switch
  end

  @doc """
  Drains any `{:email, _}` messages already in the mailbox (e.g. the
  account-confirmation email fixtures like `user_fixture/1` send), so a
  later `assert_email_sent` only sees emails sent by the code under test.
  """
  def flush_mailbox do
    receive do
      {:email, _} -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
