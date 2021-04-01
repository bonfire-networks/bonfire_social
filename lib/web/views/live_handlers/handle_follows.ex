defmodule Bonfire.Social.Web.LiveHandlers.Follows do

  alias Bonfire.Common.Utils
  import Utils
  import Phoenix.LiveView

  def handle_event("follow", %{"id"=> id}, socket) do
    with {:ok, _follow} <- Bonfire.Social.Follows.follow(e(socket.assigns, :current_user, nil), id) do
      {:noreply, assign(socket,
       following: e(socket, :assigns, :following, []) ++ [id]
     )}
    else e ->
      {:noreply, socket} # TODO: handle errors
    end
  end

  def handle_event("unfollow", %{"id"=> id}, socket) do
    with _ <- Bonfire.Social.Follows.unfollow(e(socket.assigns, :current_user, nil), id) do
      {:noreply, assign(socket,
       following: Enum.reject(e(socket, :assigns, :following, []), fn x -> x == id end)
     )}
    else e ->
      {:noreply, socket} # TODO: handle errors
    end
  end

end
