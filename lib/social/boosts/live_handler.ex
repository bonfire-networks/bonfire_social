defmodule Bonfire.Social.Boosts.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
  import Where

  def handle_event("boost", params, %{assigns: %{object: object}} = socket) do # boost in LV stateful component
    with {:ok, boost} <- Bonfire.Social.Boosts.boost(current_user(socket), object) do
      boost_action(object, true, params, socket)
    end
  end

  def handle_event("boost", %{"id"=> id} = params, socket) do # boost in LV
    with {:ok, boost} <- Bonfire.Social.Boosts.boost(current_user(socket), id) do
      boost_action(id, true, params, socket)
    end
  end

  def handle_event("undo", %{"id"=> id} = params, socket) do # unboost in LV
    with {:ok, unboost} <- Bonfire.Social.Boosts.unboost(current_user(socket), id) do
      boost_action(id, false, params, socket)
    end
  end

  defp boost_action(object, boost?, params, socket) do
    set = [my_boost: boost?]

    ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.Activity.BoostActionLive), ulid(object), set, socket)
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
