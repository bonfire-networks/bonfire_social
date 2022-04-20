defmodule Bonfire.Social.Messages.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("send", params, socket) do
    send_message(params, socket)
  end

  def send_message(params, socket) do
    attrs = params
    |> debug("attrs")
    |> input_to_atoms()
    # |> debug

    with {:ok, _sent} <- Bonfire.Social.Messages.send(current_user(socket), attrs) do
      # debug("sent!")
      {:noreply,
        socket
        |> put_flash(:info, "Sent!")
      }
    # else e ->
    #   debug(message_error: e)
    #   {:noreply,
    #     socket
    #     |> put_flash(:error, "Could not send...")
    #   }
    end
  end
end
