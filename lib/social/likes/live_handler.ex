defmodule Bonfire.Social.Likes.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("like", %{"direction"=>"up", "id"=> id}, socket) do # like in LV
    #IO.inspect(socket)
    with {:ok, _like} <- Bonfire.Social.Likes.like(e(socket.assigns, :current_user, nil), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      liked: Map.get(socket.assigns, :liked, []) ++ [id]
    )}
    end
  end

  def handle_event("like", %{"direction"=>"down", "id"=> id}, socket) do # unlike in LV
    with _ <- Bonfire.Social.Likes.unlike(e(socket.assigns, :current_user, nil), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      liked: Enum.reject(Map.get(socket.assigns, :liked, []), &Enum.member?(&1, id))
    )}
    end
  end

end
