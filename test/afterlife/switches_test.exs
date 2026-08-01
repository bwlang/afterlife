defmodule Afterlife.SwitchesTest do
  use Afterlife.DataCase

  alias Afterlife.Switches
  alias Afterlife.Switches.{ActionToken, DeliveryWorker, Switch}

  import Afterlife.SwitchesFixtures

  describe "create_switch/2" do
    test "starts active, checked in now, with next_due_at derived from the interval" do
      switch = switch_fixture(%{check_in_interval_days: 30})

      assert switch.status == "active"
      assert switch.last_check_in_at

      assert_in_delta DateTime.diff(switch.next_due_at, switch.last_check_in_at, :second),
                      30 * 86_400,
                      2
    end
  end

  describe "the state machine (docs/DESIGN.md §4)" do
    test "active becomes grace once next_due_at passes" do
      switch = switch_fixture() |> backdate!(1)

      assert {:ok, %Switch{status: "grace"} = switch} =
               Switches.advance_state(switch, DateTime.utc_now(:second))

      assert switch.next_due_at
      assert ["entered_grace"] = Switches.list_check_in_events(switch) |> Enum.map(& &1.type)
    end

    test "grace becomes triggered once the grace deadline passes" do
      switch =
        switch_fixture()
        |> then(&(Ecto.Changeset.change(&1, status: "grace") |> Repo.update!()))
        |> backdate!(1)

      assert {:ok, %Switch{status: "triggered", next_due_at: nil}} =
               Switches.advance_state(switch, DateTime.utc_now(:second))
    end

    test "advance_state is a no-op when nothing is due yet" do
      switch = switch_fixture()
      assert {:ok, ^switch} = Switches.advance_state(switch, DateTime.utc_now(:second))
    end

    test "a check-in during grace resets straight back to active" do
      switch =
        switch_fixture()
        |> then(&(Ecto.Changeset.change(&1, status: "grace") |> Repo.update!()))
        |> backdate!(1)

      assert {:ok, %Switch{status: "active"} = switch} = Switches.manual_check_in(switch)
      assert DateTime.compare(switch.next_due_at, DateTime.utc_now(:second)) == :gt
    end

    test "pause stops the countdown; resume restarts it from now" do
      switch = switch_fixture()

      assert {:ok, %Switch{status: "paused", next_due_at: nil}} = Switches.pause_switch(switch)

      paused = Switches.get_switch!(get_owner(switch), switch.id)
      assert {:ok, %Switch{status: "active"} = resumed} = Switches.resume_switch(paused)
      assert resumed.next_due_at
    end
  end

  describe "check-in audit trail" do
    test "each check-in path logs its own event type" do
      switch = switch_fixture()

      {:ok, switch} = Switches.manual_check_in(switch)
      {:ok, switch} = Switches.check_in_via_link(switch)
      {:ok, switch} = Switches.trusted_vouch(switch, 123)

      assert Switches.list_check_in_events(switch) |> Enum.map(& &1.type) |> Enum.sort() ==
               ~w(delay_clicked manual_checkin trusted_vouch) |> Enum.sort()
    end
  end

  describe "emailed check-in tokens" do
    test "a token checks in once, then is rejected on replay" do
      switch = switch_fixture()
      {:ok, raw_token} = Switches.generate_check_in_token(switch)

      assert {:ok, %Switch{}} = Switches.check_in_via_token(raw_token)
      assert {:error, :invalid_or_expired} = Switches.check_in_via_token(raw_token)
    end

    test "an expired token is rejected" do
      switch = switch_fixture()
      {:ok, raw_token} = ActionToken.generate(switch, "check_in", valid_for_days: -1)

      assert {:error, :invalid_or_expired} = Switches.check_in_via_token(raw_token)
    end

    test "garbage input is rejected, not crashed on" do
      assert {:error, :invalid_or_expired} = Switches.check_in_via_token("not-a-real-token")
    end
  end

  describe "API check-in tokens" do
    test "regenerating gives a working token, and invalidates the old one" do
      switch = switch_fixture()

      {:ok, first_token, switch} = Switches.regenerate_api_token(switch)
      assert {:ok, %Switch{}} = Switches.check_in_via_api(first_token)

      {:ok, second_token, _switch} = Switches.regenerate_api_token(switch)
      assert {:error, :invalid_token} = Switches.check_in_via_api(first_token)
      assert {:ok, %Switch{}} = Switches.check_in_via_api(second_token)
    end

    test "an unknown token is rejected" do
      assert {:error, :invalid_token} = Switches.check_in_via_api("nonexistent")
    end
  end

  describe "reminders" do
    test "a switch due within a week needs a reminder; one further out doesn't" do
      soon = switch_fixture(%{check_in_interval_days: 3})
      far = switch_fixture(%{check_in_interval_days: 30})

      due_soon = Switches.switches_needing_reminder()
      assert Enum.any?(due_soon, &(&1.id == soon.id))
      refute Enum.any?(due_soon, &(&1.id == far.id))
    end

    test "no reminder is sent again right after one already was" do
      switch = switch_fixture(%{check_in_interval_days: 3})
      Switches.record_reminder_sent(switch)

      refute Switches.switches_needing_reminder() |> Enum.any?(&(&1.id == switch.id))
    end
  end

  describe "triggering delivery" do
    # Oban.Testing's assert_enqueued/1 hardcodes a Postgres-only notifier at
    # config-build time, which blows up under the Lite (SQLite) engine — so
    # this asserts directly against oban_jobs instead, which is adapter-agnostic.
    test "enqueue_delivery schedules one unique DeliveryWorker job per (message, recipient)" do
      switch =
        switch_fixture()
        |> then(&(Ecto.Changeset.change(&1, status: "triggered") |> Repo.update!()))

      message = message_fixture(switch)
      recipient = recipient_fixture(message)

      assert :ok = Switches.enqueue_delivery(switch)
      # calling it again must not double-enqueue (unique on args)
      assert :ok = Switches.enqueue_delivery(switch)

      jobs =
        from(j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))
        |> Repo.all()

      assert [job] = jobs
      assert job.args == %{"message_id" => message.id, "recipient_id" => recipient.id}
    end

    test "triggering enqueues delivery as part of the transition itself" do
      switch = grace_switch_due_now()
      message = message_fixture(switch)
      recipient = recipient_fixture(message)

      assert {:ok, %Switch{status: "triggered"}} =
               Switches.advance_state(switch, DateTime.utc_now(:second))

      assert [job] = Repo.all(from j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))
      assert job.args == %{"message_id" => message.id, "recipient_id" => recipient.id}
    end

    # `due_for_transition/1` never returns a triggered switch, so a switch
    # marked triggered with only some recipients enqueued is never
    # revisited and the rest silently receive nothing. The status change
    # and the enqueue therefore have to land together or not at all.
    test "a failure while enqueuing rolls the trigger back rather than half-delivering" do
      switch = grace_switch_due_now()
      message = message_fixture(switch)
      recipient_fixture(message)

      # Break job insertion the way a crash or DB error would. The test
      # sandbox rolls this back along with everything else.
      Repo.query!("DROP TABLE oban_jobs")

      assert catch_error(Switches.advance_state(switch, DateTime.utc_now(:second)))

      reloaded = Repo.get!(Switch, switch.id)
      assert reloaded.status == "grace"
      refute "triggered" in Enum.map(Switches.list_check_in_events(reloaded), & &1.type)
    end
  end

  defp grace_switch_due_now do
    switch_fixture()
    |> then(&(Ecto.Changeset.change(&1, status: "grace") |> Repo.update!()))
    |> backdate!(1)
  end

  defp get_owner(%Switch{user_id: user_id}), do: Afterlife.Accounts.get_user!(user_id)
end
