defmodule Bonfire.Social.Feeds.LiveHandler do
  use Bonfire.Web, :live_handler
  require Logger
  @log_level :warn

  def handle_params(%{"after" => cursor_after} = _attrs, _, %{assigns: %{feed_id: feed_id}} = socket) do
    Logger.log(@log_level, "if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, socket, cursor_after, nil) |> assign_feed(socket)
  end

  def handle_params(%{"after" => cursor_after} = _attrs, _, socket) do
    Logger.log(@log_level, "if there's no feed_id but we have a user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed(socket, cursor_after) |> assign_feed(socket)
  end

  def handle_params(_attrs, _, socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", %{"after" => cursor_after} = _attrs, %{assigns: %{feed_id: feed_id}} = socket) do
    Logger.log(@log_level, "if a feed_id has been assigned in the view, load that")
    Bonfire.Social.FeedActivities.feed(feed_id, socket, cursor_after) |> live_more(socket)
  end

  def handle_event("load_more", %{"after" => cursor_after} = _attrs, socket) do
    Logger.log(@log_level, "if there's no feed_id but we have a user, load My Feed")
    Bonfire.Social.FeedActivities.my_feed(socket, cursor_after) |> live_more(socket)
  end


  def assign_feed(%{} = feed, socket) do
    # IO.inspect(feed_pagination: feed)

    new = [
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, []),
      feed_update_mode: "prepend"
    ]

    {:noreply, socket |> assign(new) }
  end

  def live_more(%{} = feed, socket) do
    # IO.inspect(feed_pagination: feed)

    assign_feed(feed, socket)

    # new = [
    #   feed: e(feed, :entries, []),
    #   page_info: e(feed, :metadata, [])
    # ]

    # send_update(Bonfire.UI.Social.FeedLive, [id: "feed"] ++ new)

    # {:noreply, socket}
  end

  def handle_info({:new_activity, data}, socket) do
    #IO.inspect(pubsub_received: fp)

    send_update(Bonfire.UI.Social.FeedLive, id: "feed", new_activity: data)

    {:noreply, socket}
  end

end
