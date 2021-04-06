defmodule Bonfire.Social.Web.PrivateLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Fake
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Me.Users
  alias Bonfire.Me.Web.{CreateUserLive, LoggedDashboardLive}
  import Bonfire.Me.Integration


  def mount(params, session, socket) do
    LivePlugs.live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3
    ])
  end

  defp mounted(params, session, socket) do

    current_user = e(socket, :assigns, :current_user, nil)


      {:ok,
      socket
      |> assign(
        page_title: "Private",
        page: "private",
        smart_input: true,
        has_private_tab: false,
        smart_input_placeholder: "Write a private message to one or more users",
      )}

  end

end
