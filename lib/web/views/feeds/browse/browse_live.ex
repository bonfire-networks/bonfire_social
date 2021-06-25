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
      LivePlugs.Csrf, LivePlugs.Locale,
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

  def do_handle_params(%{"tab" => "fediverse" = tab} = _params, _url, socket) do
    current_user = current_user(socket)

    if current_user || current_account(socket) do

      feed_id = Bonfire.Social.Feeds.fediverse_feed_id()
      feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

      {:noreply,
        assign(socket,
          selected_tab: tab,
          feed_title: "Activities from around the fediverse",
          feed: e(feed, :entries, []),
          page_info: e(feed, :metadata, []),
        )
        |> assign_global(to_circles: [Bonfire.Boundaries.Circles.get_tuple(:activity_pub)])
      }

    else
      do_handle_params(%{"tab" => "instance"}, nil, socket) # fallback to showing instance feed
    end
  end

  def do_handle_params(%{"tab" => "instance" = tab} = _params, _url, socket) do
    feed_id = Bonfire.Social.Feeds.instance_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    {:noreply,
      assign(socket,
        selected_tab: tab,
        feed_title: "Activities on this instance",
        feed: e(feed, :entries, []),
        page_info: e(feed, :metadata, []) |> IO.inspect
      )
      |> assign_global(to_circles: [Bonfire.Boundaries.Circles.get_tuple(:local)])
      }
  end

  def do_handle_params(_params, _url, socket) do
    default_feed(socket)
  end

  def default_feed(socket) do
    # IO.inspect(socket.assigns)
    current_user = current_user(socket)

    if current_user || current_account(socket) do
      my_feed(current_user, socket) # my feed
    else
      do_handle_params(%{"tab" => "instance"}, nil, socket) # fallback to showing instance feed
    end
  end

  def my_feed(current_user, socket) do
    # IO.inspect(myfeed: feed)
    # current_user = current_user(socket)
    feed = Bonfire.Social.FeedActivities.my_feed(socket)
    {:noreply,
      assign(socket,
      selected_tab: "feed",
      feed_title: "My Feed",
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, [])
    )
    |> assign_global(to_circles: Bonfire.Me.Users.Circles.list_my_defaults(current_user))
    }
  end


  def handle_params(params, uri, socket) do
    # IO.inspect(params)
    with {_, socket} <- undead_params(socket, fn ->
      do_handle_params(params, uri, socket)
    end) do
      # poor man's hook I guess
      Bonfire.Common.LiveHandlers.handle_params(params, uri, socket)
    end
  end

  def handle_event(action, attrs, socket), do: Bonfire.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
