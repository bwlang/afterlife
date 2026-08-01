defmodule AfterlifeWeb.MessageLive.New do
  use AfterlifeWeb, :live_view

  alias Afterlife.Switches
  alias Afterlife.Switches.{Message, Recipient}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        New message for "{@switch.name}"
      </.header>

      <.form for={@form} id="message-form" phx-submit="save" phx-change="validate" class="space-y-2">
        <.input field={@form[:subject]} type="text" label="Subject" />
        <.input field={@form[:body]} type="textarea" label="Body" />

        <.input
          type="textarea"
          name="recipients"
          id="recipients"
          label="Recipients — one per line: Name <email> or just email"
          value={@recipients_text}
        />

        <div>
          <label class="label mb-1">Attachments</label>
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
          <.button variant="primary" phx-disable-with="Saving...">Save message</.button>
          <.link navigate={~p"/switches/#{@switch}"} class="btn">Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"switch_id" => switch_id}, _session, socket) do
    switch = Switches.get_switch!(socket.assigns.current_scope.user, switch_id)

    {:ok,
     socket
     |> assign(:switch, switch)
     |> assign(:form, to_form(Switches.change_message(%Message{})))
     |> assign(:recipients_text, "")
     |> allow_upload(:attachments, accept: :any, max_entries: 5, max_file_size: 25_000_000)}
  end

  @impl true
  def handle_event("validate", params, socket) do
    form =
      %Message{}
      |> Switches.change_message(params["message"] || %{})
      |> Map.put(:action, :validate)
      |> to_form()

    recipients_text = params["recipients"] || socket.assigns.recipients_text

    {:noreply, assign(socket, form: form, recipients_text: recipients_text)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("save", params, socket) do
    recipients = Switches.parse_recipients(params["recipients"] || "")

    if recipients == [] do
      {:noreply, put_flash(socket, :error, "Add at least one recipient.")}
    else
      save_message(socket, params["message"] || %{}, recipients)
    end
  end

  defp save_message(socket, message_params, recipients) do
    switch = socket.assigns.switch

    case Switches.create_message(switch, message_params, recipients) do
      {:ok, message} ->
        consume_attachments(socket, message)

        {:noreply,
         socket
         |> put_flash(:info, "Message saved.")
         |> push_navigate(to: ~p"/switches/#{switch}")}

      # The recipients live in a free-text box, not a form field, so
      # their errors have nowhere to render inline — surface them as a
      # flash rather than dropping the address on the floor.
      {:error, %Ecto.Changeset{data: %Recipient{}} = changeset} ->
        {:noreply,
         put_flash(socket, :error, "Check the recipients: #{errors_sentence(changeset)}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp errors_sentence(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
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
