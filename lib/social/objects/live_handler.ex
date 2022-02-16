defmodule Bonfire.Social.Objects.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("delete", %{"id"=> id} = params, socket) do
    debug(id, "TODO: deletion")
    with {:ok, boost} <- Bonfire.Social.Objects.delete(current_user(socket), id) do
      {:noreply,
        socket
      }
    end
  end

end
