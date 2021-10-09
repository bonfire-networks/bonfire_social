defmodule Bonfire.Social.Web.UsersLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs

  def mount(params, session, socket) do
    LivePlugs.live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf, LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, _session, socket) do

    current_user = current_user(socket)

    {:ok,
      socket
      |> assign(
        page_title: "Users directory",
        page: "Users",
        has_private_tab: false,
        search_placeholder: "Search in users directory"
      )}
  end

end
