defmodule Bonfire.Social.Objects.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
  import Where

  def handle_event("delete", %{"id"=> id} = params, socket) do
    with {:ok, _} <- Bonfire.Social.Objects.delete(id, current_user: current_user(socket)) do
      Bonfire.UI.Social.OpenModalLive.close()

      {:noreply,
        socket
        |> put_flash(:info, "Deleted!")
      }
    end
  end

end
