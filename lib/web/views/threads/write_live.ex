defmodule Bonfire.Social.Web.WriteLive do
  use Bonfire.UI.Common.Web, :surface_view
  alias Bonfire.Me.Web.LivePlugs

  def mount(params, session, socket) do
    live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.UserRequired,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, _session, socket) do
    {:ok,
    socket
    |> assign(
      page_title: l("Write"),
      page: "write",
      create_activity_type: "",
      smart_input_text: "",
      without_sidebar: true,
      reply_to_id: nil,
      thread_id: nil,
    )}
  end


  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.UI.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
