defmodule AfterlifeWeb.Labels do
  @moduledoc """
  Human wording for the values the database stores.

  The domain calls this a switch and its end a trigger; people reading
  the screen — possibly people who did not build it, at a bad moment —
  should see a vigil that is kept and then ends. The translation lives
  here so the stored values stay stable and greppable.
  """

  @statuses %{
    "active" => "Keeping watch",
    "grace" => "Grace period",
    "paused" => "Paused",
    "triggered" => "Ended",
    "cancelled" => "Cancelled"
  }

  @events %{
    "manual_checkin" => "Checked in",
    "delay_clicked" => "Checked in from a reminder",
    "api_check_in" => "Checked in by a script",
    "trusted_vouch" => "Vouched for by a trusted contact",
    "trusted_confirm_death" => "Death confirmed by a trusted contact",
    "reminder_sent" => "Reminder sent",
    "entered_grace" => "Entered grace period",
    "triggered" => "Vigil ended — messages released",
    "paused" => "Paused",
    "resumed" => "Watch resumed"
  }

  @channels %{
    "email" => "Email",
    "dashboard" => "Here",
    "system" => "Automatic",
    "api" => "Script"
  }

  def status(value), do: Map.get(@statuses, value, value)
  def event(value), do: Map.get(@events, value, value)
  def channel(value), do: Map.get(@channels, value, value)
end
