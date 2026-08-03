defmodule AfterlifeWeb.SwitchLive.Index do
  use AfterlifeWeb, :live_view

  alias Afterlife.Switches
  alias Afterlife.Switches.Switch
  alias AfterlifeWeb.Labels

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Your vigils
        <span
          class="tooltip tooltip-bottom align-middle ml-1 before:w-80 before:whitespace-normal before:text-left"
          data-tip={@what_is_a_vigil}
          title={@what_is_a_vigil}
          tabindex="0"
        >
          <.icon name="hero-information-circle" class="size-4 opacity-50 hover:opacity-100" />
        </span>
        <:actions>
          <.link :if={@live_action != :new} patch={~p"/vigils/new"} class="btn btn-primary">
            New vigil
          </.link>
        </:actions>
      </.header>

      <.form
        :if={@live_action == :new}
        for={@form}
        id="switch-form"
        phx-submit="save"
        phx-change="validate"
        class="mt-4 mb-8 space-y-2"
      >
        <.input field={@form[:name]} type="text" label="Name" placeholder="e.g. Letters to my family" />
        <.input field={@form[:check_in_interval_days]} type="number" label="Check in every (days)" />
        <.input
          field={@form[:grace_period_days]}
          type="number"
          label="Grace period after a missed check-in (days)"
        />
        <div class="flex gap-2">
          <.button variant="primary" phx-disable-with="Creating...">Create vigil</.button>
          <.link patch={~p"/vigils"} class="btn">Cancel</.link>
        </div>
      </.form>

      <.table
        :if={@switches != []}
        id="switches"
        rows={@switches}
        row_click={fn switch -> JS.navigate(~p"/vigils/#{switch}") end}
      >
        <:col :let={switch} label="Name">{switch.name}</:col>
        <:col :let={switch} label="Status">{Labels.status(switch.status)}</:col>
        <:col :let={switch} label="Next due">{format_due(switch)}</:col>
      </.table>

      <p :if={@switches == [] and @live_action != :new} class="text-base-content/70">
        No vigils yet.
      </p>
    </Layouts.app>
    """
  end

  # Both `data-tip` (the styled tooltip) and `title` (the browser's own,
  # which screen readers announce) read from one string, so the two can't
  # drift into saying different things.
  @what_is_a_vigil "A vigil is a watch kept over someone. This one watches for you: " <>
                     "check in before the deadline and nothing happens. Stop checking in — " <>
                     "past the reminders and the grace period — and the vigil ends and your " <>
                     "messages are sent to the people you wrote them for."

  @impl true
  def mount(_params, _session, socket) do
    switches = Switches.list_switches(socket.assigns.current_scope.user)

    {:ok, assign(socket, switches: switches, what_is_a_vigil: @what_is_a_vigil)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :new) do
    assign(socket, :form, to_form(Switches.change_switch(%Switch{})))
  end

  defp apply_action(socket, :index), do: socket

  @impl true
  def handle_event("validate", %{"switch" => switch_params}, socket) do
    form =
      %Switch{}
      |> Switches.change_switch(switch_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"switch" => switch_params}, socket) do
    case Switches.create_switch(socket.assigns.current_scope.user, switch_params) do
      {:ok, switch} ->
        {:noreply,
         socket
         |> put_flash(:info, "Vigil created.")
         |> push_navigate(to: ~p"/vigils/#{switch}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp format_due(%Switch{status: "paused"}), do: "—"
  defp format_due(%Switch{next_due_at: nil}), do: "—"
  defp format_due(%Switch{next_due_at: due}), do: Calendar.strftime(due, "%Y-%m-%d %H:%M UTC")
end
