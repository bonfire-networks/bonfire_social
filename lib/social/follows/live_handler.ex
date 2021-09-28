defmodule Bonfire.Social.Follows.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("follow", %{"id"=> id}=params, socket) do
    IO.inspect(socket)

      set = [
       following: e(socket, :assigns, :following, []) ++ [id]
      ]

    with {:ok, _follow} <- Bonfire.Social.Follows.follow(current_user(socket), id) do

      ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.FollowButtonLive), id, set, socket)

    else _e ->
     # handle previously followed, but UI didn't know
      ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.FollowButtonLive), id, set, socket)

    end
  end

  def handle_event("unfollow", %{"id"=> id}=params, socket) do
    with _ <- Bonfire.Social.Follows.unfollow(current_user(socket), id) do
      set = [
       following: Enum.reject(e(socket, :assigns, :following, []), fn x -> x == id end)
      ]
     ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.FollowButtonLive), id, set, socket)
     #TODO: handle errors
    end
  end


  def preload(list_of_assigns) do
    list_of_ids = Enum.map(list_of_assigns, & e(&1, :object_id, nil)) |> Enum.reject(&is_nil/1)
    # IO.inspect(id: list_of_assigns)
    current_user = current_user(List.first(list_of_assigns))
    # IO.inspect(id: current_user)
    my_follows = if current_user, do: Bonfire.Social.Follows.get!(current_user, list_of_ids) |> Map.new(), else: %{}
    # IO.inspect(my_follows: my_follows)
    Enum.map(list_of_assigns, fn assigns ->
      # IO.inspect(id: assigns.object_id)
      Map.put(assigns, :my_follow, Map.get(my_follows, e(assigns, :object_id, nil) || e(assigns, :my_follow, nil)))
    end) #|> IO.inspect
  end

end
