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

  # WIP: Commented this as it was call anytime the user clicked on a different tab, preventing to load the right feed
  # def handle_params(_attrs, _, %{assigns: %{feed: _, page_info: pi}} = socket) when pi !=[] do
  #   # Logger.log(@log_level, "we already have a feed loaded")
  #   IO.inspect("che succede amico?")

  #   {:noreply, socket}
  # end

  def do_handle_params(%{"tab" => "fediverse" = tab} = _params, _url, socket) do
    current_user = current_user(socket)

    assigns = if current_user || current_account(socket) do

      fediverse_feed(current_user, socket)
    else
      instance_feed(current_user, socket) # fallback to showing instance feed
    end
    IO.inspect(assigns)
    {:noreply, assign(socket, assigns)}
  end

  def do_handle_params(%{"tab" => "instance" = tab} = _params, _url, socket) do
    IO.inspect("che succede amico?")
    current_user = current_user(socket)

    {:noreply, assign(socket, instance_feed(current_user, socket)) }
  end

  def do_handle_params(_params, _url, socket) do
    
    {:noreply, assign(socket, default_feed(socket))}
  end

  def default_feed(socket) do
    current_user = current_user(socket)

    if current_user || current_account(socket) do
      my_feed(current_user, socket) # my feed
    else
      instance_feed(current_user, socket) # fallback to showing instance feed
    end
  end

  def fediverse_feed(current_user, socket) do
    feed_id = Bonfire.Social.Feeds.fediverse_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)
    to_circles = [Bonfire.Boundaries.Circles.get_tuple(:activity_pub)]

    [
      selected_tab: "fediverse",
      to_circles: to_circles,
      feed_title: "Activities from around the fediverse",
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, []),
    ]
    #|> assign_global(to_circles: to_circles)
  end

  def instance_feed(_current_user, socket) do
    feed_id = Bonfire.Social.Feeds.instance_feed_id()
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)
    to_circles = [Bonfire.Boundaries.Circles.get_tuple(:local)]

    [
      selected_tab: "instance",
      feed_title: "Activities on this instance",
      to_circles: to_circles,
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, []) #|> IO.inspect
    ]
    #|> assign_global(to_circles: to_circles)
  end

  def my_feed(current_user, socket) do
    # IO.inspect(myfeed: feed)
    feed = Bonfire.Social.FeedActivities.my_feed(socket)
    to_circles = Bonfire.Me.Users.Circles.list_my_defaults(current_user)
    [
      selected_tab: "feed",
      feed_title: "My Feed",
      to_circles: to_circles,
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, [])
    ]
    #|> assign_global(to_circles: to_circles)
  end


  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <- Bonfire.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end

  def handle_event(action, attrs, socket), do: Bonfire.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
