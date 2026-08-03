defmodule AfterlifeWeb.LabelsTest do
  use ExUnit.Case, async: true

  alias Afterlife.Switches.{CheckInEvent, Switch}
  alias AfterlifeWeb.Labels

  # A stored value with no label falls through to itself, so a new
  # status shows as raw text rather than blank — visibly unfinished
  # instead of silently missing.
  test "every stored status has wording" do
    for status <- Switch.statuses() do
      assert Labels.status(status) != status, "no label for status #{status}"
    end
  end

  test "every stored event type has wording" do
    for type <- CheckInEvent.types() do
      assert Labels.event(type) != type, "no label for event #{type}"
    end
  end

  test "an unknown value falls back to itself rather than disappearing" do
    assert Labels.status("something_new") == "something_new"
    assert Labels.event("something_new") == "something_new"
  end
end
