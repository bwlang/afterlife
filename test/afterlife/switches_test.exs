defmodule Afterlife.SwitchesTest do
  use Afterlife.DataCase

  alias Afterlife.Switches
  alias Afterlife.Switches.{ActionToken, DeliveryLog, DeliveryWorker, Switch}

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

      {message, recipient} = message_with_recipient(switch)

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
      {message, recipient} = message_with_recipient(switch)

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
      message_with_recipient(switch)

      # Break job insertion the way a crash or DB error would. The test
      # sandbox rolls this back along with everything else.
      Repo.query!("DROP TABLE oban_jobs")

      assert catch_error(Switches.advance_state(switch, DateTime.utc_now(:second)))

      reloaded = Repo.get!(Switch, switch.id)
      assert reloaded.status == "grace"
      refute "triggered" in Enum.map(Switches.list_check_in_events(reloaded), & &1.type)
    end
  end

  describe "scheduled delivery (dates only — ages resolve in the UI)" do
    setup do
      switch =
        switch_fixture()
        |> then(&(Ecto.Changeset.change(&1, status: "triggered") |> Repo.update!()))

      %{switch: switch, now: ~U[2026-08-03 12:00:00Z]}
    end

    test "no date means as soon as the switch triggers", %{now: now} do
      assert Switches.deliver_after(nil, now) == nil
    end

    test "a future date becomes that day at 09:00 UTC", %{now: now} do
      assert Switches.deliver_after(~D[2038-03-14], now) == ~U[2038-03-14 09:00:00Z]
    end

    # Failing towards delivery: a letter arriving early is recoverable,
    # one that never arrives is not.
    test "a date already past sends at once rather than staying pending", %{now: now} do
      assert Switches.deliver_after(~D[1990-03-14], now) == nil
    end

    test "held copies are recorded but not enqueued at trigger", %{switch: switch} do
      {message, recipient} = message_with_recipient(switch, %{deliver_on: ~D[2038-03-14]})

      assert :ok = Switches.enqueue_delivery(switch)
      assert [] = Repo.all(from j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))

      log = Repo.get_by!(DeliveryLog, message_id: message.id, recipient_id: recipient.id)
      assert log.status == "pending"
      assert log.deliver_after == ~U[2038-03-14 09:00:00Z]
    end

    test "the sweep releases a held copy once its date arrives", %{switch: switch} do
      {message, recipient} = message_with_recipient(switch, %{deliver_on: ~D[2038-03-14]})

      assert :ok = Switches.enqueue_delivery(switch)
      Switches.enqueue_due_deliveries(~U[2038-03-14 10:00:00Z])

      assert [job] = Repo.all(from j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))
      assert job.args == %{"message_id" => message.id, "recipient_id" => recipient.id}
    end

    test "a held copy stays held until then", %{switch: switch} do
      message_with_recipient(switch, %{deliver_on: ~D[2038-03-14]})

      assert :ok = Switches.enqueue_delivery(switch)
      Switches.enqueue_due_deliveries(~U[2038-03-13 09:00:00Z])

      assert [] = Repo.all(from j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))
    end

    test "recipients of the same message can be due on different dates", %{switch: switch} do
      early = recipient_fixture(switch, %{name: "Early"})
      late = recipient_fixture(switch, %{name: "Late"})

      message =
        message_fixture(switch, %{
          schedules: [
            %{recipient_id: early.id, deliver_on: nil},
            %{recipient_id: late.id, deliver_on: ~D[2038-03-14]}
          ]
        })

      assert :ok = Switches.enqueue_delivery(switch)

      assert [job] = Repo.all(from j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))
      assert job.args == %{"message_id" => message.id, "recipient_id" => early.id}
    end
  end

  describe "birthday_at_age/2 (input-layer helper)" do
    test "gives the date someone reaches an age" do
      assert Switches.birthday_at_age(~D[2020-03-14], 18) == ~D[2038-03-14]
    end

    test "29 February falls back to the 28th in a non-leap year" do
      assert Switches.birthday_at_age(~D[2020-02-29], 17) == ~D[2037-02-28]
    end
  end

  defp grace_switch_due_now do
    switch_fixture()
    |> then(&(Ecto.Changeset.change(&1, status: "grace") |> Repo.update!()))
    |> backdate!(1)
  end

  defp get_owner(%Switch{user_id: user_id}), do: Afterlife.Accounts.get_user!(user_id)
end
