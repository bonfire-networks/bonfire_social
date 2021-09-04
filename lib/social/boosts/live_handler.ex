defmodule Bonfire.Social.Boosts.LiveHandler do
  use Bonfire.Web, :live_handler
  alias Bonfire.Common.Web.ComponentID

  def handle_event("boost", %{"id"=> id}, socket) do # boost in LV
    #IO.inspect(socket)
    with {:ok, _boost} <- Bonfire.Social.Boosts.boost(current_user(socket), id) do

      set = [my_boost: nil, boosted: Map.get(socket.assigns, :boosted, []) ++ [id]]

      ComponentID.send_updates(Bonfire.UI.Social.Activity.BoostActionLive, id, set)

      {:noreply, Phoenix.LiveView.assign(socket, set)}
    end
  end

  def handle_event("undo", %{"id"=> id}, socket) do # unboost in LV
    with _ <- Bonfire.Social.Boosts.unboost(current_user(socket), id) do

      set = [my_boost: nil, boosted: Map.get(socket.assigns, :boosted, []) |> List.delete(id)]

      ComponentID.send_updates(Bonfire.UI.Social.Activity.BoostActionLive, id, set)

      {:noreply, Phoenix.LiveView.assign(socket,
      set
    )}
    end
  end

end
