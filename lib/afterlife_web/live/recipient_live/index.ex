defmodule AfterlifeWeb.RecipientLive.Index do
  @moduledoc """
  Everyone across the account's switches, in one place.

  Recipients are editable here rather than only on the switch that owns
  them because one birthday is used by every message addressed to that
  person — correcting it has to be possible without hunting through
  messages.
  """

  use AfterlifeWeb, :live_view

  alias Afterlife.Switches

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Recipients
        <:subtitle>
          The people your messages can be addressed to. A birthday is only needed to hold a
          message until someone reaches a given age.
        </:subtitle>
      </.header>

      <p :if={@recipients == []} class="text-base-content/70">
        No recipients yet. Add them from a <.link navigate={~p"/switches"} class="link">switch</.link>.
      </p>

      <div :for={recipient <- @recipients} class="border-b border-base-200 py-3">
        <.form for={@forms[recipient.id]} id={"recipient-#{recipient.id}"} phx-submit="save">
          <input type="hidden" name="recipient_id" value={recipient.id} />
          <div class="flex flex-wrap gap-2 items-end">
            <.input field={@forms[recipient.id][:name]} type="text" label="Name" />
            <.input field={@forms[recipient.id][:email]} type="email" label="Email" />
            <.input field={@forms[recipient.id][:birthdate]} type="date" label="Birthday" />
            <.button variant="primary" phx-disable-with="Saving...">Save</.button>
            <.link
              phx-click="delete"
              phx-value-id={recipient.id}
              data-confirm={"Remove #{recipient.name}? Messages addressed only to them will have no recipients."}
              class="link text-error text-sm pb-3"
            >
              Remove
            </.link>
          </div>
          <p class="text-xs text-base-content/60 mt-1">
            on switch
            <.link navigate={~p"/switches/#{recipient.switch}"} class="link">
              {recipient.switch.name}
            </.link>
          </p>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("save", %{"recipient_id" => id} = params, socket) do
    recipient = Switches.get_user_recipient!(socket.assigns.current_scope.user, id)

    case Switches.update_recipient(recipient, params["recipient"] || %{}) do
      {:ok, _updated} ->
        {:noreply, socket |> load() |> put_flash(:info, "Recipient updated.")}

      {:error, changeset} ->
        forms = Map.put(socket.assigns.forms, recipient.id, to_form(changeset))
        {:noreply, assign(socket, :forms, forms)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket.assigns.current_scope.user
    |> Switches.get_user_recipient!(id)
    |> Switches.delete_recipient()

    {:noreply, socket |> load() |> put_flash(:info, "Recipient removed.")}
  end

  defp load(socket) do
    recipients = Switches.list_all_recipients(socket.assigns.current_scope.user)

    forms =
      Map.new(recipients, fn recipient ->
        {recipient.id, to_form(Switches.change_recipient(recipient))}
      end)

    socket |> assign(:recipients, recipients) |> assign(:forms, forms)
  end
end
