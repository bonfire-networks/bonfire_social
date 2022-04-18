defmodule Bonfire.Social.Messages.LiveHandler do
  use Bonfire.Web, :live_handler

  def send_message(params, socket) do
    attrs = params
    |> input_to_atoms()
    # |> IO.inspect

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
