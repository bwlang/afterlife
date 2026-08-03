defmodule Afterlife.Switches.SweepWorkerTest do
  use Afterlife.DataCase

  import Swoosh.TestAssertions
  import Afterlife.SwitchesFixtures

  alias Afterlife.Switches
  alias Afterlife.Switches.{DeliveryWorker, SweepWorker, Switch}

  describe "reminders" do
    test "emails the owner for a switch due within a week, and logs it" do
      switch = switch_fixture(%{check_in_interval_days: 3})
      flush_mailbox()

      assert :ok = SweepWorker.perform(%Oban.Job{})

      assert_email_sent(subject: ~r/^Check in on "#{Regex.escape(switch.name)}"/)
      assert ["reminder_sent"] = Switches.list_check_in_events(switch) |> Enum.map(& &1.type)
    end

    test "doesn't send a second reminder right after the first" do
      switch_fixture(%{check_in_interval_days: 3})
      flush_mailbox()

      assert :ok = SweepWorker.perform(%Oban.Job{})
      assert_email_sent()

      assert :ok = SweepWorker.perform(%Oban.Job{})
      refute_email_sent()
    end

    test "leaves a switch that isn't due soon alone" do
      switch_fixture(%{check_in_interval_days: 30})
      flush_mailbox()

      assert :ok = SweepWorker.perform(%Oban.Job{})
      refute_email_sent()
    end
  end

  describe "liveness signal (docs/DESIGN.md §0)" do
    # GET /health reports the age of the last *completed* sweep, and Oban
    # only marks a job completed when perform/1 returns :ok. That return
    # value is therefore the liveness signal itself — if a sweep ever
    # ends any other way, the monitor is meant to see staleness.
    test "a clean sweep returns :ok, which is what Oban records as completed" do
      switch_fixture(%{check_in_interval_days: 3})

      assert :ok = SweepWorker.perform(%Oban.Job{})
    end
  end

  describe "state transitions" do
    test "moves an active switch with a missed check-in into grace" do
      switch = switch_fixture() |> backdate!(1)

      assert :ok = SweepWorker.perform(%Oban.Job{})

      assert %Switch{status: "grace"} = Repo.get!(Switch, switch.id)
    end

    test "triggers a switch once its grace period elapses and enqueues delivery" do
      switch =
        switch_fixture()
        |> then(&(Ecto.Changeset.change(&1, status: "grace") |> Repo.update!()))
        |> backdate!(1)

      {message, recipient} = message_with_recipient(switch)

      assert :ok = SweepWorker.perform(%Oban.Job{})

      assert %Switch{status: "triggered"} = Repo.get!(Switch, switch.id)

      jobs =
        from(j in Oban.Job, where: j.worker == ^inspect(DeliveryWorker))
        |> Repo.all()

      assert [job] = jobs
      assert job.args == %{"message_id" => message.id, "recipient_id" => recipient.id}
    end
  end
end
