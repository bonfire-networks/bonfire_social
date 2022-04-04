defmodule Bonfire.Social.Feeds.LiveHandler do
  use Bonfire.Web, :live_handler
  import Where

  def handle_params(%{"after" => _cursor_after} = opts, _, %{assigns: %{feed_id: feed_id}} = socket) when not is_nil(feed_id) do
    debug("Feeds - paginate with params - if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, [current_user: current_user(socket), paginate: opts])
    |> assign_feed(socket)
  end

  def handle_params(%{"after" => _cursor_after} = opts, _, socket) do
    debug("Feeds - paginate with params - if there's no feed_id but we have a current_user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed([current_user: current_user(socket), paginate: opts])
    |> assign_feed(socket)
  end

  def handle_params(_attrs, _, socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", opts, %{assigns: %{feed_id: feed_id}} = socket) when not is_nil(feed_id) do
    debug("Feeds - paginate with live event - if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, [current_user: current_user(socket), paginate: opts])
    |> live_more(socket)
  end

  def handle_event("load_more", opts, socket) do

    debug("Feeds - paginate with live event - if there's no feed_id but we have a current_user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed([current_user: current_user(socket), paginate: opts])
    |> live_more(socket)
  end


  def assign_feed(%{} = feed, socket) do
    new = [
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []),
      feed_update_mode: "append"
    ]

    {:noreply, socket |> assign(new) }
  end

  def live_more(%{} = feed, socket) do
    # debug(feed_pagination: feed)

    assign_feed(feed, socket)

    # new = [
    #   feed: e(feed, :edges, []),
    #   page_info: e(feed, :page_info, [])
    # ]

    # send_update(Bonfire.UI.Social.FeedLive, [id: "feed"] ++ new)

    # {:noreply, socket}
  end

  def handle_info({:new_activity, data}, socket) do
    debug(data[:feed_ids], "handle_info :new_activity")
    # debug(data)
    current_user = current_user(socket)

    permitted? = Bonfire.Common.Pointers.exists?([id: e(data, :activity, :object, :id, nil)], current_user: current_user) |> debug("check boundary upon receiving a LivePush")

    if permitted? && is_list(data[:feed_ids]) do
      my_home_feed_ids = Bonfire.Social.Feeds.my_home_feed_ids(current_user)
      feed_ids = if Enum.any?(data[:feed_ids], fn feed_id -> feed_id in my_home_feed_ids end) do
        data[:feed_ids] ++ [Bonfire.Social.Feeds.my_feed_id(:inbox, current_user)]
      else
        data[:feed_ids]
      end

      debug(feed_ids, "send_update to feeds")

      send_updates(feed_ids, data[:activity])
    end
    {:noreply, socket}
  end

  def send_updates(feed_ids, activity) do
    for feed_id <- feed_ids do
      # debug(feed_id, "New activity for feed")
      send_update(Bonfire.UI.Social.FeedLive, id: feed_id, new_activity: activity)
    end
  end

  def default_feed_assigns(socket) do
    current_user = current_user(socket)
    current_account = current_account(socket)

    current = current_user || current_account

    if current do
      my_feed_assigns(current, socket) # my feed
    else
      instance_feed_assigns(socket) # fallback to showing instance feed
    end
  end

  def fediverse_feed_assigns(socket) do
    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    [
      current_user: current_user(socket),
      selected_tab: "fediverse",
      page_title: "Federation",
      feed_title: "Activities from around the fediverse",
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []),
    ]
  end

  def instance_feed_assigns(socket) do
    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    [
      current_user: current_user(socket),
      selected_tab: "instance",
      page_title: "Local",
      feed_title: "Activities on this instance",
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []) #|> IO.inspect
    ]
  end

  def my_feed_assigns(current_user, socket) do
    # debug(myfeed: feed)
    feed_id = Bonfire.Social.Feeds.my_feed_id(:inbox, socket)
    feed = Bonfire.Social.FeedActivities.my_feed(socket)
    [
      current_user: current_user,
      selected_tab: "home",
      page_title: "Home",
      feed_title: "My Feed",
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, [])
    ]
  end

end
