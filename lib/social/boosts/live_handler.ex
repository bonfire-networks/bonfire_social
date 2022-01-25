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

  def preload(list_of_assigns) do
    current_user = current_user(List.first(list_of_assigns))
    # |> debug("current_user")

    list_of_objects = list_of_assigns
    |> Enum.map(& e(&1, :object, nil))
    |> repo().maybe_preload(:boost_count)
    # |> debug("list_of_objects")

    list_of_ids = list_of_objects
    |> Enum.map(& e(&1, :id, nil))
    |> filter_empty([])
    |> debug("list_of_ids")

    my_states = if current_user, do: Bonfire.Social.Boosts.get!(current_user, list_of_ids, preload: false) |> Map.new(fn l -> {e(l, :edge, :object_id, nil), true} end), else: %{}
    debug(my_states, "my_boosts")

    objects_counts = list_of_objects |> Map.new(fn o -> {e(o, :id, nil), e(o, :boost_count, :object_count, nil)} end)
    |> debug("boost_counts")

    list_of_assigns
    |> Enum.map(fn assigns ->
      object_id = e(assigns, :object, :id, nil)

      assigns
      |> Map.put(
        :my_boost,
        Map.get(my_states, object_id)
      )
      |> Map.put(
        :boost_count,
        Map.get(objects_counts, object_id)
      )
    end)
  end

end
