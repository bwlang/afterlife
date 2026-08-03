defmodule AfterlifeWeb.MessageLive.Form do
  use AfterlifeWeb, :live_view

  alias Afterlife.Switches
  alias Afterlife.Switches.Message

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {if @live_action == :edit, do: "Editing a message for", else: "New message for"} "{@switch.name}"
      </.header>

      <.form for={@form} id="message-form" phx-submit="save" phx-change="validate" class="space-y-2">
        <.input field={@form[:subject]} type="text" label="Subject" />
        <.input field={@form[:body]} type="textarea" label="Body" />

        <div>
          <label class="label mb-1">Recipients</label>
          <p :if={@recipients == []} class="text-sm text-base-content/70">
            No recipients on this switch yet — add them on the
            <.link navigate={~p"/vigils/#{@switch}"} class="link">vigil page</.link>
            first.
          </p>
          <label :for={recipient <- @recipients} class="flex items-center gap-2 py-1">
            <input
              type="checkbox"
              name="recipient_ids[]"
              value={recipient.id}
              checked={recipient.id in @selected_ids}
              class="checkbox checkbox-sm"
            />
            <span>{recipient.name} &lt;{recipient.email}&gt;</span>
            <span :if={recipient.birthdate} class="text-xs text-base-content/60">
              born {Calendar.strftime(recipient.birthdate, "%Y-%m-%d")}
            </span>
          </label>
        </div>

        <div>
          <label class="label mb-1">When to send</label>
          <select name="schedule[mode]" class="select select-bordered w-full">
            <option value="trigger" selected={@schedule.mode == "trigger"}>
              As soon as the switch triggers
            </option>
            <option value="date" selected={@schedule.mode == "date"}>
              On a specific date
            </option>
            <option value="age" selected={@schedule.mode == "age"}>
              When each recipient reaches an age
            </option>
          </select>
        </div>

        <.input
          :if={@schedule.mode == "date"}
          type="date"
          name="schedule[date]"
          id="schedule_date"
          label="Send on"
          value={@schedule.date}
        />

        <.input
          :if={@schedule.mode == "age"}
          type="number"
          name="schedule[age]"
          id="schedule_age"
          label="Age"
          value={@schedule.age}
        />

        <div :if={@horizons != []} class="text-sm rounded bg-base-200 p-2 space-y-1">
          <p class="font-semibold">When each copy would arrive</p>
          <p :for={{name, description} <- @horizons}>
            {name}: {description}
          </p>
          <p class="text-warning">
            A held message needs this app — host, domain, mail credentials and encryption
            key — to still be running on that date, with nobody left to fix it.
          </p>
        </div>

        <div>
          <label class="label mb-1">Attachments</label>
          <div :for={attachment <- @existing_attachments} class="text-sm">
            {attachment.filename} ({attachment.byte_size} bytes)
            <.link
              phx-click="delete_attachment"
              phx-value-id={attachment.id}
              data-confirm="Remove this attachment?"
              class="link text-error"
            >
              remove
            </.link>
          </div>
          <.live_file_input upload={@uploads.attachments} />
          <div :for={entry <- @uploads.attachments.entries} class="text-sm mt-1">
            {entry.client_name} ({entry.client_size} bytes)
            <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref} class="link">
              cancel
            </button>
            <span :for={err <- upload_errors(@uploads.attachments, entry)} class="text-error text-sm">
              {error_to_string(err)}
            </span>
          </div>
        </div>

        <div class="flex gap-2 pt-2">
          <.button variant="primary" phx-disable-with="Saving...">
            {if @live_action == :edit, do: "Save changes", else: "Save message"}
          </.button>
          <.link navigate={~p"/vigils/#{@switch}"} class="btn">Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"switch_id" => switch_id} = params, _session, socket) do
    switch = Switches.get_switch!(socket.assigns.current_scope.user, switch_id)

    socket =
      socket
      |> assign(:switch, switch)
      |> assign(:recipients, Switches.list_recipients(switch))
      |> allow_upload(:attachments, accept: :any, max_entries: 5, max_file_size: 25_000_000)

    {:ok, apply_action(socket, socket.assigns.live_action, switch, params)}
  end

  defp apply_action(socket, :new, _switch, _params) do
    socket
    |> assign(:message, nil)
    |> assign(:form, to_form(Switches.change_message(%Message{})))
    |> assign(:selected_ids, [])
    |> assign(:schedule, %{mode: "trigger", date: nil, age: nil})
    |> assign(:existing_attachments, [])
    |> assign(:horizons, [])
  end

  defp apply_action(socket, :edit, %{status: "triggered"} = switch, _params) do
    socket
    |> put_flash(
      :error,
      "This vigil has already triggered — its messages can no longer be changed."
    )
    |> push_navigate(to: ~p"/vigils/#{switch}")
    |> assign(message: nil, form: to_form(Switches.change_message(%Message{})))
    |> assign(selected_ids: [], schedule: %{mode: "trigger", date: nil, age: nil})
    |> assign(existing_attachments: [], horizons: [])
  end

  defp apply_action(socket, :edit, switch, %{"id" => id}) do
    message = Switches.get_message!(switch, id)
    schedule = schedule_of(message)

    socket
    |> assign(:message, message)
    |> assign(:form, to_form(Switches.change_message(message)))
    |> assign(:selected_ids, Enum.map(message.message_recipients, & &1.recipient_id))
    |> assign(:schedule, schedule)
    |> assign(:existing_attachments, message.attachments)
    |> assign(
      :horizons,
      horizons(
        socket.assigns.recipients,
        Enum.map(message.message_recipients, & &1.recipient_id),
        schedule
      )
    )
  end

  # Stored dates come back as a fixed date: the age that produced them
  # isn't kept, because the delivery path doesn't deal in ages.
  defp schedule_of(message) do
    case Enum.find(message.message_recipients, & &1.deliver_on) do
      nil -> %{mode: "trigger", date: nil, age: nil}
      link -> %{mode: "date", date: Date.to_iso8601(link.deliver_on), age: nil}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    form =
      %Message{}
      |> Switches.change_message(params["message"] || %{})
      |> Map.put(:action, :validate)
      |> to_form()

    selected = selected_ids(params)
    schedule = schedule_from(params)

    {:noreply,
     socket
     |> assign(form: form, selected_ids: selected, schedule: schedule)
     |> assign(:horizons, horizons(socket.assigns.recipients, selected, schedule))}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("delete_attachment", %{"id" => id}, socket) do
    message = socket.assigns.message

    message
    |> Switches.get_attachment!(id)
    |> Switches.delete_attachment()

    message = Switches.get_message!(socket.assigns.switch, message.id)

    {:noreply,
     socket
     |> assign(:message, message)
     |> assign(:existing_attachments, message.attachments)
     |> put_flash(:info, "Attachment removed.")}
  end

  def handle_event("save", params, socket) do
    case selected_ids(params) do
      [] ->
        {:noreply, put_flash(socket, :error, "Choose at least one recipient.")}

      ids ->
        schedules = schedules_for(socket.assigns.recipients, ids, schedule_from(params))
        save_message(socket, params["message"] || %{}, schedules)
    end
  end

  defp schedule_from(params) do
    schedule = params["schedule"] || %{}

    %{
      mode: schedule["mode"] || "trigger",
      date: schedule["date"],
      age: schedule["age"]
    }
  end

  # Ages and birthdays end here. Everything below the context deals in
  # dates, so the translation happens once, at the point the message is
  # written, and is visible on screen before it is saved.
  defp schedules_for(recipients, selected_ids, schedule) do
    recipients
    |> Enum.filter(&(&1.id in selected_ids))
    |> Enum.map(&%{recipient_id: &1.id, deliver_on: deliver_on_for(&1, schedule)})
  end

  defp deliver_on_for(_recipient, %{mode: "date", date: date}) when date not in [nil, ""] do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      {:error, _} -> nil
    end
  end

  defp deliver_on_for(%{birthdate: %Date{} = birthdate}, %{mode: "age", age: age})
       when age not in [nil, ""] do
    case Integer.parse(age) do
      {years, ""} when years > 0 -> Switches.birthday_at_age(birthdate, years)
      _ -> nil
    end
  end

  defp deliver_on_for(_recipient, _schedule), do: nil

  # An age hides how long the wait is: age 18 is five years for a
  # thirteen-year-old and eighteen for a newborn. Resolved here so the
  # real date is on screen before the message is saved. Measured from
  # today, so it over-states — the wait really starts at trigger, later.
  defp horizons(_recipients, _selected, %{mode: "trigger"}), do: []

  defp horizons(recipients, selected, schedule) do
    recipients
    |> Enum.filter(&(&1.id in selected))
    |> Enum.map(&{&1.name, horizon(&1, schedule)})
  end

  defp horizon(recipient, schedule) do
    now = DateTime.utc_now()

    case Switches.deliver_after(deliver_on_for(recipient, schedule), now) do
      nil when schedule.mode == "age" and is_nil(recipient.birthdate) ->
        "no birthday recorded, so this copy goes as soon as the vigil ends"

      nil ->
        "as soon as the vigil ends"

      due ->
        years = div(DateTime.diff(due, now, :day), 365)
        "#{Calendar.strftime(due, "%-d %B %Y")} — about #{years} years from now"
    end
  end

  defp selected_ids(params) do
    params
    |> Map.get("recipient_ids", [])
    |> Enum.map(&String.to_integer/1)
  end

  defp save_message(%{assigns: %{message: %Message{} = message}} = socket, attrs, schedules) do
    switch = socket.assigns.switch

    case Switches.update_message(switch, message, attrs, schedules) do
      {:ok, updated} ->
        consume_attachments(socket, updated)

        {:noreply,
         socket
         |> put_flash(:info, "Message updated.")
         |> push_navigate(to: ~p"/vigils/#{switch}")}

      {:error, :already_triggered} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "This vigil has already triggered — its messages can no longer be changed."
         )
         |> push_navigate(to: ~p"/vigils/#{switch}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_message(socket, message_params, recipient_ids) do
    switch = socket.assigns.switch

    case Switches.create_message(switch, message_params, recipient_ids) do
      {:ok, message} ->
        consume_attachments(socket, message)

        {:noreply,
         socket
         |> put_flash(:info, "Message saved.")
         |> push_navigate(to: ~p"/vigils/#{switch}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  #
  # `path` here is Phoenix.LiveView's own generated temp-upload path
  # (Plug.Upload's tmp dir), never derived from the user-supplied
  # filename/path — there's nothing attacker-controlled to traverse with.
  defp consume_attachments(socket, message) do
    consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
      content = File.read!(path)

      Switches.add_attachment(message, %{
        filename: entry.client_name,
        content_type: entry.client_type,
        byte_size: entry.client_size,
        content: content
      })

      {:ok, entry.client_name}
    end)
  end

  defp error_to_string(:too_large), do: "Too large"
  defp error_to_string(:too_many_files), do: "Too many files"
  defp error_to_string(:not_accepted), do: "Unacceptable file type"
  defp error_to_string(_other), do: "Upload failed"
end
