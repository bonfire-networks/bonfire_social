defmodule Bonfire.Social.Messages.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("send", params, socket) do
    send_message(params, socket)
  end

  def handle_event("select_recipient", %{"id"=> id, "name"=>name}, socket) do
    debug(id: id)
    debug("add to circles")
    debug(e(socket, :to_circles, []))
    to_circles = [{name, id} | e(socket, :to_circles, [])]
    debug(to_circles)
    {:noreply,
      assign(socket, to_circles: to_circles)
    }
  end


  def send_message(params, socket) do
    attrs = params
    |> debug("attrs")
    |> input_to_atoms()
    # |> debug

    with {:ok, sent} <- Bonfire.Social.Messages.send(current_user(socket), attrs) do
      debug(sent, "sent!")
      {:noreply,
        socket
        |> put_flash(:info, "Sent!")
        |> push_redirect(to: "/messages/#{e(sent, :replied, :thread_id, nil) || ulid(sent)}##{ulid(sent)}") # FIXME: assign or pubsub the new message and patch instead
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
