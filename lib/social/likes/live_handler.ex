defmodule Bonfire.Social.Likes.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("like", %{"direction"=>"up", "id"=> id}, socket) do # like in LV
    #IO.inspect(socket)
    with {:ok, like} <- Bonfire.Social.Likes.like(current_user(socket), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      my_like: like,
      like_count: liker_count(socket)+1
      # liked: Map.get(socket.assigns, :liked, []) ++ [id]
    )}
    end
  end

  def handle_event("like", %{"direction"=>"down", "id"=> id}, socket) do # unlike in LV
    with _ <- Bonfire.Social.Likes.unlike(current_user(socket), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      my_like: nil,
      like_count: liker_count(socket)-1
      # liked: Enum.reject(Map.get(socket.assigns, :liked, []), &Enum.member?(&1, id))
    )}
    end
  end

  def liker_count(%{assigns: a}), do: liker_count(a)
  def liker_count(%{like_count: like_count}), do: liker_count(like_count)
  def liker_count(%{liker_count: liker_count}), do: liker_count(liker_count)
  def liker_count(liker_count) when is_integer(liker_count), do: liker_count
  def liker_count(_), do: 0

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
