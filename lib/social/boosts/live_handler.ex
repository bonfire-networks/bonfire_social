defmodule Bonfire.Social.Boosts.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("boost", %{"id"=> id} = params, socket) do # boost in LV
    #IO.inspect(socket)
    with {:ok, boost} <- Bonfire.Social.Boosts.boost(current_user(socket), id) do

      set = [my_boost: boost, boosted: Map.get(socket.assigns, :boosted, []) ++ [id]]

      ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.Activity.BoostActionLive), id, set, socket)

    end
  end

  def handle_event("undo", %{"id"=> id} = params, socket) do # unboost in LV
    with _ <- Bonfire.Social.Boosts.unboost(current_user(socket), id) do

      set = [my_boost: nil, boosted: Map.get(socket.assigns, :boosted, []) |> List.delete(id)]

      ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.Activity.BoostActionLive), id, set, socket)

    end
  end

end
