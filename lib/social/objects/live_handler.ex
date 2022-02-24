defmodule Bonfire.Social.Objects.LiveHandler do
  use Bonfire.Web, :live_handler
  import Where

  def handle_event("delete", %{"id"=> id} = params, socket) do
    debug(id, "TODO: deletion")
    with {:ok, _} <- Bonfire.Social.Objects.delete(current_user(socket), id) do
      Bonfire.UI.Social.OpenModalLive.close()

      {:noreply,
        socket
        |> put_flash(:info, "Deleted!")
      }
    end
  end

end
