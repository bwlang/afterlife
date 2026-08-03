defmodule AfterlifeWeb.SwitchLive.Show do
  use AfterlifeWeb, :live_view

  alias Afterlife.Switches
  alias Afterlife.Switches.{Recipient, Switch}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@switch.name}
        <:subtitle>
          Status: <span class={status_class(@switch.status)}>{@switch.status}</span>
          · {due_summary(@switch)}
        </:subtitle>
        <:actions>
          <.button phx-click="check_in" variant="primary">I'm still here</.button>
          <.button :if={@switch.status != "paused"} phx-click="pause">Pause</.button>
          <.button :if={@switch.status == "paused"} phx-click="resume" variant="primary">
            Resume
          </.button>
        </:actions>
      </.header>

      <div class="divider">Settings</div>

      <.form
        for={@settings_form}
        id="settings-form"
        phx-submit="save_settings"
        phx-change="validate_settings"
        class="space-y-2"
      >
        <.input field={@settings_form[:name]} type="text" label="Name" />
        <.input
          field={@settings_form[:check_in_interval_days]}
          type="number"
          label="Check in every (days)"
        />
        <.input
          field={@settings_form[:grace_period_days]}
          type="number"
          label="Grace period after a missed check-in (days)"
        />
        <.button variant="primary" phx-disable-with="Saving...">Save settings</.button>
      </.form>

      <div class="divider">API check-in</div>

      <p class="text-sm text-base-content/70">
        Let another tool or script check in on your behalf — a presence monitor, a cron job,
        anything that can make an HTTP request to a URL only you have.
      </p>
      <.button phx-click="regenerate_api_token" class="mt-2">
        {if @switch.api_token_hash, do: "Regenerate", else: "Generate"} API check-in URL
      </.button>
      <div :if={@api_check_in_url} class="mt-2 p-2 rounded bg-base-200 break-all text-sm">
        <strong>Copy this now — it won't be shown again:</strong><br /> {@api_check_in_url}
      </div>

      <div class="divider">Recipients</div>

      <p class="text-sm text-base-content/70">
        The people your messages can be addressed to. A birthday is only needed if you
        want to hold a message until they reach a certain age.
      </p>

      <.form for={@recipient_form} id="recipient-form" phx-submit="add_recipient" class="mt-2">
        <div class="flex flex-wrap gap-2 items-end">
          <.input field={@recipient_form[:name]} type="text" label="Name" />
          <.input field={@recipient_form[:email]} type="email" label="Email" />
          <.input field={@recipient_form[:birthdate]} type="date" label="Birthday (optional)" />
          <.button variant="primary" phx-disable-with="Adding...">Add</.button>
        </div>
      </.form>

      <.table :if={@recipients != []} id="recipients" rows={@recipients}>
        <:col :let={recipient} label="Name">{recipient.name}</:col>
        <:col :let={recipient} label="Email">{recipient.email}</:col>
        <:col :let={recipient} label="Birthday">
          {if recipient.birthdate, do: Calendar.strftime(recipient.birthdate, "%Y-%m-%d"), else: "—"}
        </:col>
        <:col :let={recipient} label="">
          <.link
            phx-click="delete_recipient"
            phx-value-id={recipient.id}
            data-confirm="Remove this person? Messages addressed only to them will have no recipients."
            class="link text-error text-sm"
          >
            Remove
          </.link>
        </:col>
      </.table>

      <div class="divider">Messages</div>

      <.link navigate={~p"/switches/#{@switch}/messages/new"} class="btn btn-primary btn-sm">
        New message
      </.link>

      <.list :if={@messages != []}>
        <:item :for={message <- @messages} title={message.subject}>
          <.link
            :if={@switch.status != "triggered"}
            navigate={~p"/switches/#{@switch}/messages/#{message}/edit"}
            class="link text-sm"
          >
            Edit
          </.link>
          <br /> To: {Enum.map_join(message.recipients, ", ", & &1.email)}
          <div :if={held?(message)} class="text-xs text-base-content/70 mt-1">
            <div :for={{recipient, due} <- message.schedule}>
              {recipient.name}: {due_description(due)}
            </div>
          </div>
          <span :if={message.attachments != []}>· {length(message.attachments)} attachment(s)</span>
        </:item>
      </.list>
      <p :if={@messages == []} class="text-base-content/70 mt-2">No messages yet.</p>

      <div class="divider">Activity log</div>

      <.table id="events" rows={@events}>
        <:col :let={event} label="When">
          {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M UTC")}
        </:col>
        <:col :let={event} label="Type">{event.type}</:col>
        <:col :let={event} label="Channel">{event.channel}</:col>
        <:col :let={event} label="From">
          <span class="font-mono text-xs">{event.ip_address || "—"}</span>
        </:col>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    switch = Switches.get_switch!(socket.assigns.current_scope.user, id)

    {:ok,
     socket
     |> assign(:api_check_in_url, nil)
     # Messages are only ever added from another page, so they're loaded
     # once here rather than on every check-in/pause/settings change.
     |> assign(:messages, Switches.list_messages(switch))
     |> assign_recipients(switch)
     |> assign_switch(switch)}
  end

  @impl true
  def handle_event("add_recipient", %{"recipient" => params}, socket) do
    case Switches.add_recipient(socket.assigns.switch, params) do
      {:ok, _recipient} ->
        {:noreply,
         socket
         |> assign_recipients(socket.assigns.switch)
         |> put_flash(:info, "Recipient added.")}

      {:error, changeset} ->
        {:noreply, assign(socket, recipient_form: to_form(changeset))}
    end
  end

  def handle_event("delete_recipient", %{"id" => id}, socket) do
    switch = socket.assigns.switch

    switch
    |> Switches.get_recipient!(id)
    |> Switches.delete_recipient()

    {:noreply,
     socket
     |> assign_recipients(switch)
     |> assign(:messages, Switches.list_messages(switch))
     |> put_flash(:info, "Recipient removed.")}
  end

  def handle_event("check_in", _params, socket) do
    {:ok, switch} = Switches.manual_check_in(socket.assigns.switch)
    {:noreply, socket |> assign_switch(switch) |> put_flash(:info, "Checked in.")}
  end

  def handle_event("pause", _params, socket) do
    {:ok, switch} = Switches.pause_switch(socket.assigns.switch)
    {:noreply, socket |> assign_switch(switch) |> put_flash(:info, "Switch paused.")}
  end

  def handle_event("resume", _params, socket) do
    {:ok, switch} = Switches.resume_switch(socket.assigns.switch)
    {:noreply, socket |> assign_switch(switch) |> put_flash(:info, "Switch resumed.")}
  end

  def handle_event("validate_settings", %{"switch" => switch_params}, socket) do
    form =
      socket.assigns.switch
      |> Switches.change_switch(switch_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, settings_form: form)}
  end

  def handle_event("save_settings", %{"switch" => switch_params}, socket) do
    case Switches.update_switch_settings(socket.assigns.switch, switch_params) do
      {:ok, switch} ->
        {:noreply, socket |> assign_switch(switch) |> put_flash(:info, "Settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, settings_form: to_form(changeset))}
    end
  end

  def handle_event("regenerate_api_token", _params, socket) do
    {:ok, raw_token, switch} = Switches.regenerate_api_token(socket.assigns.switch)
    url = url(~p"/api/check_in/#{raw_token}")

    {:noreply,
     socket
     |> assign(:switch, switch)
     |> assign(:api_check_in_url, url)}
  end

  # Everything that changes when the switch itself does: the audit log
  # gains a row, and the settings form re-renders from the saved values.
  defp assign_recipients(socket, switch) do
    socket
    |> assign(:recipients, Switches.list_recipients(switch))
    |> assign(:recipient_form, to_form(Switches.change_recipient(%Recipient{})))
  end

  defp assign_switch(socket, switch) do
    socket
    |> assign(:switch, switch)
    |> assign(:events, Switches.list_check_in_events(switch))
    |> assign(:settings_form, to_form(Switches.change_switch(switch)))
  end

  defp held?(message), do: Enum.any?(message.schedule, fn {_recipient, due} -> due end)

  defp due_description(nil), do: "as soon as the switch triggers"

  defp due_description(due) do
    years = div(DateTime.diff(due, DateTime.utc_now(), :day), 365)
    "#{Calendar.strftime(due, "%-d %B %Y")} (about #{years} years away)"
  end

  defp status_class("active"), do: "badge badge-success"
  defp status_class("grace"), do: "badge badge-warning"
  defp status_class("triggered"), do: "badge badge-error"
  defp status_class("paused"), do: "badge badge-neutral"
  defp status_class(_), do: "badge"

  defp due_summary(%Switch{status: "paused"}), do: "not counting down"
  defp due_summary(%Switch{next_due_at: nil}), do: ""

  defp due_summary(%Switch{next_due_at: due}) do
    days = DateTime.diff(due, DateTime.utc_now(), :day)
    "due #{Calendar.strftime(due, "%Y-%m-%d")} (#{days} day(s))"
  end
end
