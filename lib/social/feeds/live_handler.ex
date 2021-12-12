defmodule Bonfire.Social.Feeds.LiveHandler do
  use Bonfire.Web, :live_handler
  require Logger
  @log_level :warn

  def handle_params(%{"after" => _cursor_after} = opts, _, %{assigns: %{feed_id: feed_id}} = socket) do
    Logger.log(@log_level, "if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, socket, [paginate: opts], nil) |> assign_feed(socket)
  end

  def handle_params(%{"after" => _cursor_after} = opts, _, socket) do
    Logger.log(@log_level, "if there's no feed_id but we have a user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed(socket, paginate: opts) |> assign_feed(socket)
  end

  def handle_params(_attrs, _, socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", opts, %{assigns: %{feed_id: feed_id}} = socket) do
    Logger.log(@log_level, "if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, socket, paginate: opts) |> live_more(socket)
  end

  def handle_event("load_more", opts, socket) do
    Logger.log(@log_level, "if there's no feed_id but we have a user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed(socket, paginate: opts) |> live_more(socket)
  end


  def assign_feed(%{} = feed, socket) do
    # IO.inspect(feed_pagination: feed)

    new = [
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []),
      feed_update_mode: "prepend"
    ]

    {:noreply, socket |> assign(new) }
  end

  def live_more(%{} = feed, socket) do
    # IO.inspect(feed_pagination: feed)

    assign_feed(feed, socket)

    # new = [
    #   feed: e(feed, :edges, []),
    #   page_info: e(feed, :page_info, [])
    # ]

    # send_update(Bonfire.UI.Social.FeedLive, [id: "feed"] ++ new)

    # {:noreply, socket}
  end

  def handle_info({:new_activity, data}, socket) do
    #IO.inspect(pubsub_received: fp)

    current_user_id = e(current_user(socket), :id, nil)

    if current_user_id do
        send_update(Bonfire.UI.Social.FeedLive, id: "feed:my:"<>current_user_id, new_activity: data)
    end

    {:noreply, socket}
  end

end
