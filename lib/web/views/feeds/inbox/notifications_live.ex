defmodule Bonfire.Social.Web.Feeds.NotificationsLive do
  use Bonfire.UI.Common.Web, :surface_view
  alias Bonfire.Me.Web.LivePlugs

  def mount(params, session, socket) do
    live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.AccountRequired,
      # LivePlugs.LoadCurrentAccountUsers,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3,
    ]
  end

  defp mounted(params, _session, socket) do

    current_user = current_user(socket)
    feed_id = Bonfire.Social.Feeds.my_feed_id(:notifications, socket)
    feed = Bonfire.Social.FeedActivities.feed(:notifications, current_user: current_user) # TODO: avoid two queries for feed_id?

    {:ok, socket
    |> assign(
      page: "notifications",
      selected_tab: "notifications",
      page_title: l("Notifications"),
      current_user: current_user,
      feed_id: feed_id,
      feed: e(feed, :edges, []),
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

  defdelegate handle_params(params, attrs, socket), to: Bonfire.UI.Common.LiveHandlers
  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.UI.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
