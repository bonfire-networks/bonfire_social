defmodule Bonfire.Social.Likes.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("like", %{"direction"=>"up", "id"=> id}, socket) do # like in LV
    #IO.inspect(socket)
    with {:ok, _like} <- Bonfire.Social.Likes.like(current_user(socket), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      liked: Map.get(socket.assigns, :liked, []) ++ [id]
    )}
    end
  end

  def handle_event("like", %{"direction"=>"down", "id"=> id}, socket) do # unlike in LV
    with _ <- Bonfire.Social.Likes.unlike(current_user(socket), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      liked: Enum.reject(Map.get(socket.assigns, :liked, []), &Enum.member?(&1, id))
    )}
    end
  end

  def preload(list_of_assigns) do
    list_of_ids = Enum.map(list_of_assigns, & &1.object_id)
    # IO.inspect(id: list_of_assigns)
    current_user = current_user(List.first(list_of_assigns))
    # IO.inspect(id: current_user)
    my_likes = if current_user, do: Bonfire.Social.Likes.get!(current_user, list_of_ids) |> Map.new(), else: %{}
    # IO.inspect(my_likes: my_likes)
    Enum.map(list_of_assigns, fn assigns ->
      Map.put(assigns, :my_like, Map.get(my_likes, assigns.object_id))
    end)
  end

end
