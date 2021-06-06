defmodule Bonfire.Social.Flags.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("flag", %{"id"=> id}, socket) do # flag in LV
    #IO.inspect(socket)
    with {:ok, _flag} <- Bonfire.Social.Flags.flag(e(socket.assigns, :current_user, nil), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      flagged: Map.get(socket.assigns, :flagged, []) ++ [{id, true}]
    )}
    end
  end

  def handle_event("unflag", %{"id"=> id}, socket) do # unflag in LV
    with _ <- Bonfire.Social.Flags.unflag(e(socket.assigns, :current_user, nil), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      flagged: Map.get(socket.assigns, :flagged, []) ++ [{id, false}]
    )}
    end
  end

end
