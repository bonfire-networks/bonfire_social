defmodule Bonfire.Social.Feeds.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler
  import Where

  def handle_params(%{"after" => _cursor_after} = attrs, _, %{assigns: %{feed_id: feed_id}} = socket) when not is_nil(feed_id) do
    input_to_atoms(attrs)
    |> info("Feeds - paginate with params - since a feed_id has been assigned in the view, load that")
    |> Bonfire.Social.FeedActivities.feed(feed_id, [current_user: current_user(socket), paginate: ...])
    |> assign_feed(socket)
  end

  def handle_params(%{"after" => _cursor_after} = attrs, _, socket) do
    input_to_atoms(attrs)
    |> info("Feeds - paginate with params - there's no feed_id, so load default feed")
    |> {:noreply, socket |> assign(default_feed_assigns([current_user: current_user(socket), paginate: ...]))}
  end

  def handle_params(_attrs, _, socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", attrs, %{assigns: %{feed_id: feed_id}} = socket) when not is_nil(feed_id) do
    input_to_atoms(attrs)
    |> debug("Feeds - paginate with live event - if a feed_id has been assigned in the view, load that")
    |> Bonfire.Social.FeedActivities.feed(feed_id, [current_user: current_user(socket), paginate: ...])
    |> assign_feed(socket)
  end

  def handle_event("load_more", attrs, socket) do
    input_to_atoms(attrs)
    |> debug("Feeds - paginate with live event - if there's no feed_id so load the default")
    |> {:noreply, socket |> assign(default_feed_assigns([current_user: current_user(socket), paginate: ...]))}
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
        e(socket, :assigns, :object_id, nil)
          || e(socket, :assigns, :object, :id, nil)
          || e(activity, :object, :id, nil),
      # thread_id: activity_id,
      activity: activity,
      object: e(socket, :assigns, :object, nil),
      smart_input_text: mentions,
      to_circles: to_circles,
      activity_inception: "reply_to",
      preset_boundary: Bonfire.Boundaries.preset_boundary_name_from_acl(e(socket, :assigns, :object_boundary, nil))
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

  def handle_info({:new_activity, data}, socket) do
    debug(data[:feed_ids], "received new_activity for feeds")
    # info(data)
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

  def default_feed_assigns(socket_or_opts) do
    current_user = current_user(socket_or_opts)
    current_account = current_account(socket_or_opts)

    current = current_user || current_account

    if current do
      my_feed_assigns(current, socket_or_opts) # my feed
    else
      instance_feed_assigns(socket_or_opts) # fallback to showing instance feed
    end
  end

  def fediverse_feed_assigns(socket_or_opts) do
    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket_or_opts)

    [
      current_user: current_user(socket_or_opts),
      selected_tab: "fediverse",
      page_title: l("Federated activities from remote instances"),
      page: "federation",
      feed_title: l("Activities from around the fediverse"),
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []),
    ]
  end

  def instance_feed_assigns(socket_or_opts) do
    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket_or_opts)

    [
      current_user: current_user(socket_or_opts),
      selected_tab: "instance",
      page_title: l("Local activities"),
      page: "local",
      feed_title: l("Activities on this instance"),
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []) #|> IO.inspect
    ]
  end

  def my_feed_assigns(current_user, socket_or_opts) do
    # debug(myfeed: feed)
    feed_id = Bonfire.Social.Feeds.my_feed_id(:inbox, socket_or_opts)
    feed_ids = Bonfire.Social.Feeds.my_home_feed_ids(socket_or_opts)
    feed = Bonfire.Social.FeedActivities.feed(feed_ids, socket_or_opts)
    [
      current_user: current_user,
      selected_tab: "home",
      page_title: l("Home"),
      feed_title: l("My Feed"),
      feed_id: feed_id,
      feed_ids: feed_ids,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, [])
    ]
  end

end
