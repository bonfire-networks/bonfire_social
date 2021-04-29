defmodule Bonfire.Social.Web.Feeds.BrowseLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Web.LivePlugs

  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3,
    ]
  end

  defp mounted(_params, _session, socket) do

    # feed = Bonfire.Social.FeedActivities.my_feed(socket)

    {:ok, socket
    |> assign(
      page: "browse",
      page_title: "Browse",
      selected_tab: "feed",
      smart_input: true,
      has_private_tab: false,
      smart_input_placeholder: "Write something meaningful",
      feed_title: "Browse",
      feed: [],
      page_info: []
      )}
  end

  def do_handle_params(%{"tab" => "fediverse" = tab} = _params, _url, %{assigns: %{current_user: %{id: _} = current_user}} = socket) do
    # current_user = e(socket.assigns, :current_user, nil)
    feed_id = Bonfire.Social.Feeds.fediverse_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    {:noreply,
      assign(socket,
        selected_tab: tab,
        feed_title: "Browse the fediverse",
        feed: e(feed, :entries, []),
        page_info: e(feed, :metadata, []),
      )
      |> cast_self(to_circles: [Bonfire.Boundaries.Circles.get_tuple(:activity_pub)])
    }
  end

  def do_handle_params(%{"tab" => "instance" = tab} = _params, _url, socket) do
    current_user = e(socket.assigns, :current_user, nil)
    feed_id = Bonfire.Social.Feeds.instance_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    {:noreply,
      assign(socket,
        selected_tab: tab,
        feed_title: "Browse the local instance",
        feed: e(feed, :entries, []),
        page_info: e(feed, :metadata, [])
      )
      |> cast_self(to_circles: [Bonfire.Boundaries.Circles.get_tuple(:local)])
      }
  end


  def do_handle_params(%{"tab" => "feed" = _tab} = _params, _url, socket) do

    do_handle_params(nil, nil, socket) # my feed (if logged in)
  end

  def do_handle_params(_params, _url, %{assigns: %{current_user: %{id: _} = current_user}} = socket) do
    # IO.inspect(myfeed: feed)
    # current_user = e(socket.assigns, :current_user, nil)
    feed = Bonfire.Social.FeedActivities.my_feed(socket)
    {:noreply,
     assign(socket,
     selected_tab: "feed",
     feed_title: "Browse your feed",
     feed: e(feed, :entries, []),
     page_info: e(feed, :metadata, [])
    )
    |> cast_self(to_circles: Bonfire.Me.Users.Circles.list_my_defaults(current_user))
    }
  end

  def do_handle_params(_params, url, socket) do
    IO.inspect(socket.assigns)
    do_handle_params(%{"tab" => "instance"}, url, socket) # fallback to showing instance feed
  end

  def handle_params(params, uri, socket) do
    # IO.inspect(params)
    undead_params(socket, fn ->
      do_handle_params(params, uri, socket)
    end)
  end

  def handle_event(action, attrs, socket), do: Bonfire.Web.LiveHandler.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Web.LiveHandler.handle_info(info, socket, __MODULE__)

end
