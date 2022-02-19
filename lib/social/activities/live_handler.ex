defmodule Bonfire.Social.Feeds.LiveHandler do
  use Bonfire.Web, :live_handler
  import Where

  def handle_params(%{"after" => _cursor_after} = opts, _, %{assigns: %{feed_id: feed_id}} = socket) do
    debug("Feeds - paginate with params - if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, [socket: socket, paginate: opts]) |> assign_feed(socket)
  end

  def handle_params(%{"after" => _cursor_after} = opts, _, socket) do
    debug("Feeds - paginate with params - if there's no feed_id but we have a current_user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed([socket: socket, paginate: opts]) |> assign_feed(socket)
  end

  def handle_params(_attrs, _, socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", opts, %{assigns: %{feed_id: feed_id}} = socket) do
    debug("Feeds - paginate with live event - if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, [socket: socket, paginate: opts]) |> live_more(socket)
  end

  def handle_event("load_more", opts, socket) do

    debug("Feeds - paginate with live event - if there's no feed_id but we have a current_user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed([socket: socket, paginate: opts])
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
    debug("Feeds - handle_info :new_activity")
    # debug(data: data)

    current_user_id = e(current_user(socket), :id, nil)

    if current_user_id do
      debug("Feeds - send_update to feed:my:#{inspect current_user_id}")
      send_update(Bonfire.UI.Social.FeedLive, id: "feed:my:"<>current_user_id, new_activity: data)
    end

    {:noreply, socket}
  end

end
