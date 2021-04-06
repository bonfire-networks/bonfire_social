defmodule Bonfire.Social.Web.Feeds.BrowseLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Fake
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Me.Users
  alias Bonfire.Me.Web.{CreateUserLive}
  alias Bonfire.UI.Social.FeedLive
  import Bonfire.Me.Integration

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

    # feed = Bonfire.Social.FeedActivities.my_feed(socket.assigns.current_user)

    {:ok, socket
    |> assign(
      page: "browse",
      page_title: "Browse",
      selected_tab: "feed",
      smart_input: true,
      has_private_tab: false,
      smart_input_placeholder: "Write something meaningful",
      feed_title: "Browse",
      # feed: e(feed, :entries, []),
      # page_info: e(feed, :metadata, [])
      )}
  end

  def do_handle_params(%{"tab" => "fediverse" = tab} = _params, _url, socket) do
    current_user = e(socket.assigns, :current_user, nil)
    feed_id = Bonfire.Social.Feeds.fediverse_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, current_user)

    {:noreply,
      assign(socket,
        selected_tab: tab,
        feed: e(feed, :entries, []),
        page_info: e(feed, :metadata, [])
      )}
  end

  def do_handle_params(%{"tab" => "instance" = tab} = _params, _url, socket) do
    current_user = e(socket.assigns, :current_user, nil)
    feed_id = Bonfire.Social.Feeds.instance_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, current_user)

    {:noreply,
      assign(socket,
        selected_tab: tab,
        feed: e(feed, :entries, []),
        page_info: e(feed, :metadata, [])
      )}
  end


  def do_handle_params(%{"tab" => "feed" = tab} = _params, _url, socket) do

    do_handle_params(%{}, nil, socket)
  end

  def do_handle_params(%{"tab" => tab} = _params, _url, socket) do
    IO.inspect(tab: tab)
    {:noreply,
     assign(socket,
       selected_tab: tab
     )}
  end

  def do_handle_params(%{} = _params, _url, socket) do
    IO.inspect("feed: feed")
    current_user = e(socket.assigns, :current_user, nil)
    feed = Bonfire.Social.FeedActivities.my_feed(current_user)
    {:noreply,
     assign(socket,
     selected_tab: "feed",
     feed: e(feed, :entries, []),
     page_info: e(feed, :metadata, [])
     )}
  end

  def handle_params(params, uri, socket) do
    IO.inspect(params)
    undead_params(socket, fn ->
      do_handle_params(params, uri, socket)
    end)
  end


  defdelegate handle_params(params, attrs, socket), to: Bonfire.Web.LiveHandler
  def handle_event(action, attrs, socket), do: Bonfire.Web.LiveHandler.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Web.LiveHandler.handle_info(info, socket, __MODULE__)

end
