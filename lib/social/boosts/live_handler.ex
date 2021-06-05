defmodule Bonfire.Social.Boosts.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("boost", %{"id"=> id}, socket) do # boost in LV
    #IO.inspect(socket)
    with {:ok, _boost} <- Bonfire.Social.Boosts.boost(e(socket.assigns, :current_user, nil), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      boosted: Map.get(socket.assigns, :boosted, []) ++ [id]
    )}
    end
  end

  def handle_event("boost_undo", %{"id"=> id}, socket) do # unboost in LV
    with _ <- Bonfire.Social.Boosts.unboost(e(socket.assigns, :current_user, nil), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      boosted: Map.get(socket.assigns, :boosted, []) ++ [id]
    )}
    end
  end

end
