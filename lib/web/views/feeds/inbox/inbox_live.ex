defmodule Bonfire.Social.Web.Feeds.InboxLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Fake
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Me.Users
  alias Bonfire.Me.Web.{CreateUserLive}
  alias Bonfire.UI.Social.FeedLive
  alias Bonfire.Me.Fake


  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3,
    ]
  end

  defp mounted(params, session, socket) do
    current_user = Map.get(socket.assigns, :current_user)

    user = case Map.get(params, "username") do
      nil -> e(socket.assigns, :current_user, Fake.user_live())
      username ->
        with {:ok, user} <- Bonfire.Me.Users.by_username(username) do
          user
        end
    end

    feed_id = Bonfire.Social.Feeds.my_inbox_feed_id(socket.assigns)
    IO.inspect(feed_id: feed_id)

    feed = Bonfire.Social.FeedActivities.feed(feed_id, e(socket.assigns, :current_user, nil), nil, [:default]) # FIXME: for some reason preloading creator or reply_to when we have a boost in inbox breaks ecto

    {:ok, socket
    |> assign(
      page: "notifications",
      page_title: "Notifications",
      feed_title: "Notifications",
      smart_input: false,
      feed_id: feed_id,
      user: user,
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, [])
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

  defdelegate handle_params(params, attrs, socket), to: Bonfire.Web.LiveHandler
  def handle_event(action, attrs, socket), do: Bonfire.Web.LiveHandler.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Web.LiveHandler.handle_info(info, socket, __MODULE__)

end
