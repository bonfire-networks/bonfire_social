defmodule Bonfire.Social.Feeds.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
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

  def handle_event("reply", _, socket) do
    debug("reply!")

    activity = e(socket, :assigns, :activity, nil)
    participants = Bonfire.Social.Threads.list_participants(activity, nil, current_user: current_user(socket))

    to_circles = if length(participants)>0, do: Enum.map(participants, & {e(&1, :character, :username, l "someone"), e(&1, :id, nil)})

    mentions = if length(participants)>0, do: Enum.map_join(participants, " ", & "@"<>e(&1, :character, :username, ""))<>" "

    send_update(Bonfire.UI.Social.SmartInputLive,
      id: :smart_input,
      # reply to objects, not activities
      reply_to_id:
        e(socket, :assigns, :object_id, nil) || e(socket, :assigns, :object, :id, nil) ||
          e(activity, :object, :id, nil),
      # thread_id: activity_id,
      activity: activity,
      object: e(socket, :assigns, :object, nil),
      smart_input_text: mentions,
      to_circles: to_circles,
      activity_inception: "reply_to"
    )

    {:noreply, socket}
  end

  def handle_event("remove_data", _params, socket) do
    send_update(Bonfire.UI.Social.SmartInputLive, [
      id: :smart_input,
      activity: nil,
      object: nil,
      reply_to_id: nil])
    {:noreply, socket}
  end

  def handle_event("delete", %{"id"=> id} = params, socket) do
    # TODO: check permission
    with num when is_integer(num) <- Bonfire.Social.FeedActivities.delete(id) do
      Bonfire.UI.Social.OpenModalLive.close()

      {:noreply,
        socket
        |> put_flash(:info, l("Deleted from %{number} feeds!", number: num))
      }
    end
  end

  def handle_event("open_activity", %{"ignore" => "true"} = _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_activity", %{"permalink" => permalink} = _params, socket) do
    debug("Redirect to the activity page")
    {:noreply,
      socket
      |> push_redirect(to: permalink)
    }
  end

  def handle_event("open_activity", _params, socket) do
    {:noreply, socket}
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
    debug(data[:feed_ids], "received new_activity for feeds")
    dump(data)
    current_user = current_user(socket)

    permitted? = Bonfire.Common.Pointers.exists?([id: e(data, :activity, :object, :id, nil)], current_user: current_user) |> debug("checked boundary upon receiving a LivePush")

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
      page_title: l("Federated activities from remote instances"),
      page: "federation",
      feed_title: l("Activities from around the fediverse"),
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
      page_title: l("Local activities"),
      page: "local",
      feed_title: l("Activities on this instance"),
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
      page_title: l("Home"),
      feed_title: l("My Feed"),
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, [])
    ]
  end

end
