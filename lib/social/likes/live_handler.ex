defmodule Bonfire.Social.Likes.LiveHandler do
  use Bonfire.Web, :live_handler
  require Logger

  def handle_event("like", %{"direction"=>"up", "id"=> id} = params, socket) do # like in LV
    #IO.inspect(socket)

    with {:ok, like} <- Bonfire.Social.Likes.like(current_user(socket), id) do
      set_liked(id, like, params, socket)

    else {:error, %Ecto.Changeset{errors: [
       liker_id: {"has already been taken",
        _}
     ]}} ->
      Logger.info("previously liked, but UI didn't know")
      set_liked(id, %{id: true}, params, socket)
    end
  end

  def set_liked(id, like, params, socket) do
    set = [
        my_like: like,
        like_count: liker_count(params)+1,
        # liked: Map.get(socket.assigns, :liked, []) ++ [id]
      ]

      ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.LikeActionLive), id, set, socket)

  end


  def handle_event("like", %{"direction"=>"down", "id"=> id} = params, socket) do # unlike in LV
    with _ <- Bonfire.Social.Likes.unlike(current_user(socket), id) do
      set = [
      my_like: nil,
      like_count: liker_count(params)-1
      # liked: Enum.reject(Map.get(socket.assigns, :liked, []), &Enum.member?(&1, id))
      ]

    ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.LikeActionLive), id, set, socket)

    end
  end


  def liker_count(%{"current_count"=> a}), do: a |> String.to_integer
  def liker_count(%{current_count: a}), do: a |> String.to_integer
  # def liker_count(%{assigns: a}), do: liker_count(a)
  # def liker_count(%{like_count: like_count}), do: liker_count(like_count)
  # def liker_count(%{liker_count: liker_count}), do: liker_count(liker_count)
  # def liker_count(liker_count) when is_integer(liker_count), do: liker_count
  def liker_count(_), do: 0

  def preload(list_of_assigns) do
    list_of_ids = Enum.map(list_of_assigns, & e(&1, :object_id, nil)) |> Enum.reject(&is_nil/1)
    # IO.inspect(id: list_of_assigns)
    current_user = current_user(List.first(list_of_assigns))
    IO.inspect(current_user: current_user)
    my_likes = if current_user, do: Bonfire.Social.Likes.get!(current_user, list_of_ids) |> Map.new(), else: %{}
    IO.inspect(my_likes: my_likes)
    Enum.map(list_of_assigns, fn assigns ->
      Map.put(assigns, :my_like, Map.get(my_likes, e(assigns, :object_id, nil) || e(assigns, :my_like, nil)))
    end)
  end

end
