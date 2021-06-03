defmodule Bonfire.Social.Web.LiveHandlers.Feeds do
  use Bonfire.Web, :live_handler

  def handle_params(%{"after" => cursor_after} = _attrs, _, %{assigns: %{feed_id: feed_id}} = socket) do # if a feed_id has been assigned in the view, load that
    Bonfire.Social.FeedActivities.feed(feed_id, socket, cursor_after, nil) |> live_more(socket)
  end

  def handle_params(%{"after" => cursor_after} = _attrs, _, %{assigns: %{current_user: current_user}} = socket) do # if there's no feed_id but we have a user, load "My Feed"
    Bonfire.Social.FeedActivities.my_feed(socket, cursor_after) |> live_more(socket)
  end

  def handle_event("feed_load_more", %{"after" => cursor_after} = _attrs, %{assigns: %{feed_id: feed_id}} = socket) do # if a feed_id has been assigned in the view, load that
    Bonfire.Social.FeedActivities.feed(feed_id, socket, cursor_after) |> live_more(socket)
  end

  def handle_event("feed_load_more", %{"after" => cursor_after} = _attrs, %{assigns: %{current_user: current_user}} = socket) do # if there's no feed_id but we have a user, load "My Feed"
    Bonfire.Social.FeedActivities.my_feed(socket, cursor_after) |> live_more(socket)
  end

  def live_more(%{} = feed, socket) do
    #IO.inspect(feed_pagination: feed)

    new = [
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, [])
    ]

    send_update(Bonfire.UI.Social.FeedLive, [id: "feed"] ++ new)

    {:noreply, socket}
  end

  def handle_info({:feed_new_activity, data}, socket) do
    #IO.inspect(pubsub_received: fp)

    send_update(Bonfire.UI.Social.FeedLive, id: "feed", feed_new_activity: data)

    {:noreply, socket}
  end

end
