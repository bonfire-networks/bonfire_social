defmodule Bonfire.Social.Web.LiveHandlers.Boosts do
  use Bonfire.Web, :live_handler


  def handle_event("boost", %{"id"=> id}, socket) do # boost in LV
    #IO.inspect(socket)
    with {:ok, _boost} <- Bonfire.Social.Boosts.boost(socket.assigns.current_user, id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      boosted: Map.get(socket.assigns, :boosted, []) ++ [id]
    )}
    end
  end

  def handle_event("boost_undo", %{"id"=> id}, socket) do # unboost in LV
    with _ <- Bonfire.Social.Boosts.unboost(socket.assigns.current_user, id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      boosted: Map.get(socket.assigns, :boosted, []) ++ [id]
    )}
    end
  end

end
