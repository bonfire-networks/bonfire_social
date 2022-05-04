defmodule Bonfire.Social.Flags.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  def handle_event("flag", %{"id"=> id}, socket) do # flag in LV
    #debug(socket)
    with {:ok, _flag} <- Bonfire.Social.Flags.flag(current_user(socket), id) do

      Bonfire.UI.Social.OpenModalLive.close()

      {:noreply, socket
      |> put_flash(:info, "Flagged!")
      |> assign(
        flagged: Map.get(socket.assigns, :flagged, []) ++ [{id, true}]
      )}
    end
  end

  def handle_event("unflag", %{"id"=> id} = attrs, socket) do # unflag in LV
    current_user = current_user(socket)
    subject = if attrs["subject"] && Bonfire.Me.Users.is_admin?(current_user), do: Bonfire.Me.Users.by_id(attrs["subject"], current_user: current_user) |> ok_or(nil), else: current_user

    with _ <- Bonfire.Social.Flags.unflag(subject, id) do
      {:noreply, socket
      |> put_flash(:info, "Unflagged!")
      |> assign(
      flagged: Map.get(socket.assigns, :flagged, []) ++ [{id, false}]
    )}
    end
  end

end
