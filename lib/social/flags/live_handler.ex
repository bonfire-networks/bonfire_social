defmodule Bonfire.Social.Flags.LiveHandler do
  use Bonfire.Web, :live_handler

  def handle_event("flag", %{"id"=> id}, socket) do # flag in LV
    #IO.inspect(socket)
    with {:ok, _flag} <- Bonfire.Social.Flags.flag(current_user(socket), id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      flagged: Map.get(socket.assigns, :flagged, []) ++ [{id, true}]
    )}
    end
  end

  def handle_event("unflag", %{"id"=> id} = attrs, socket) do # unflag in LV
    current_user = current_user(socket)
    subject = if attrs["subject"] && Bonfire.Me.Users.is_admin?(current_user), do: Bonfire.Me.Users.by_id(attrs["subject"]) |> ok_or(nil), else: current_user
    with _ <- Bonfire.Social.Flags.unflag(subject, id) do
      {:noreply, Phoenix.LiveView.assign(socket,
      flagged: Map.get(socket.assigns, :flagged, []) ++ [{id, false}]
    )}
    end
  end

end
