defmodule Bonfire.Social.Web.FlagsLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs

  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf, LivePlugs.Locale,
      &mounted/3,
    ]
  end

  defp mounted(params, _session, socket) do

    feed = Bonfire.Social.FeedActivities.feed(:flags, socket)
    edges = for %{edge: %{} = edge} <- e(feed, :edges, []), do: %{activity: edge |> Map.put(:verb, %{verb: "flag"})} #|> debug

    {:ok, socket
    |> assign(
      page: "flags",
      selected_tab: "flags",
      page_title: "Flags",
      current_user: current_user(socket),
      feed_id: :flags,
      feed: edges,
      page_info: e(feed, :page_info, [])
      )}

  end


  # def handle_params(%{"tab" => tab} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      selected_tab: tab
  #    )}
  # end

  # def handle_params(%{} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      current_user: Fake.user_live()
  #    )}
  # end

  defdelegate handle_params(params, attrs, socket), to: Bonfire.Common.LiveHandlers
  def handle_event(action, attrs, socket), do: Bonfire.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
