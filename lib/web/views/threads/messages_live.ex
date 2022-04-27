defmodule Bonfire.Social.Web.MessagesLive do
  use Bonfire.Web, {:surface_view, [layout: {Bonfire.UI.Social.Web.LayoutView, "without_sidebar.html"}]}
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Social.Integration
  import Where

  def mount(params, session, socket) do
    LivePlugs.live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.UserRequired,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf, LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, _session, socket) do
    {:ok,
      socket
      |> assign(
        page_title: l("Private Message"),
        page: "messages",
        has_private_tab: false,
        activity: nil,
        object: nil,
        reply_to_id: nil,
        thread_id: nil
      )
      |> assign_global(
        search_placeholder: l("Search this discussion"),
        create_activity_type: :message,
        smart_input_prompt: l("Compose a thoughtful message...")
      )
    }
  end

  def do_handle_params(%{"username" => username} = params, url, socket) do

    current_user = current_user(socket)
    current_username = e(current_user, :character, :username, nil)

    user = case username do
      nil ->
        current_user

      username when username == current_username ->
        current_user

      username ->
        with {:ok, user} <- Bonfire.Me.Users.by_username(username) do
          user
        else _ ->
          nil
        end
    end
    # debug(user: user)

    if user do

      smart_input_text = if e(current_user, :character, :username, "") == e(user, :character, :username, ""), do:
      "", else: "@"<>e(user, :character, :username, "")<>" "

      feed = if current_user, do: if module_enabled?(Bonfire.Social.Messages), do: Bonfire.Social.Messages.list(current_user, ulid(e(socket.assigns, :user, nil)), latest_in_threads: true, limit: 10) #|> debug()

      {:noreply,
        socket
        |> assign(
          page: "private",
          feed: e(feed, :edges, []),
          smart_input: true,
          tab_id: "compose",
          has_private_tab: true,
          feed_title: l("Messages"),
          user: user, # the user to display
          reply_to_id: nil,
          thread_id: nil,
          smart_input_prompt: l("Compose a thoughtful message..."),
          # smart_input_text: smart_input_text,
          to_circles: [{e(user, :profile, :name, e(user, :character, :username, l "someone")), e(user, :id, nil)}]
        )
      }
    else
      {:noreply,
        socket
        |> put_flash(:error, l("User not found"))
        |> push_redirect(to: "/error")
      }
    end
  end

  def do_handle_params(%{"id" => "compose" = id} = params, url, socket) do
    current_user = current_user(socket)
    users = Bonfire.Social.Follows.list_my_followed(current_user) |> debug("USERS")

    {:noreply,
    socket
    |> assign(
      page_title: l("Direct Messages"),
      page: "messages",
      users: e(users, :edges, []),
      tab_id: "select_recipients",
      reply_to_id: nil,
      thread_id: nil
      )
    }
  end

  def do_handle_params(%{"id" => id} = params, url, socket) do
    if not is_ulid?(id) do
      do_handle_params(%{"username" => id}, url, socket)
    else
      current_user = current_user(socket)

      with {:ok, message} <- Bonfire.Social.Messages.read(id, current_user: current_user) do
        dump(message, "the queried message")

        {activity, message} = Map.pop(message, :activity)
        {preloaded_object, activity} = Map.pop(activity, :object)
        activity = Bonfire.Social.Activities.activity_preloads(activity, :all, current_user: current_user)

        message = Map.merge(message, preloaded_object)
                |> debug("the message object")

        reply_to_id = e(params, "reply_to_id", id)
        thread_id = e(activity, :replied, :thread_id, id)

        # debug(activity, "activity")
        smart_input_prompt = l("Reply to message:")<>" "<>text_only(e(message, :post_content, :name, e(message, :post_content, :summary, e(message, :post_content, :html_body, reply_to_id))))

        participants = Bonfire.Social.Threads.list_participants(activity, thread_id, current_user: current_user)

        to_circles = if length(participants)>0, do: Enum.map(participants, & {e(&1, :character, :username, l "someone"), e(&1, :id, nil)})

        names = if length(participants)>0, do: Enum.map_join(participants, ", ", &e(&1, :profile, :name, e(&1, :character, :username, l "someone else")))

        # mentions = if length(participants)>0, do: Enum.map_join(participants, " ", & "@"<>e(&1, :character, :username, ""))<>" "

        prompt =  l("Compose a thoughtful response") #  if mentions, do: "for %{people}", people: mentions), else: l "Note to self..."

        title = if names, do: l("Conversation with %{people}", people: names), else: l "Conversation"

        {:noreply,
        socket
        |> assign(
          page_title: title,
          page: "message",
          has_private_tab: false,
          tab_id: "thread",
          reply_to_id: reply_to_id,
          url: url,
          activity: activity,
          object: message,
          thread_id: e(message, :id, nil),
          participants: participants,
          smart_input_prompt: prompt,
          to_circles: to_circles || []
        )
      }

      else _e ->
        {:error, l("Not found (or you don't have permission to view this message)")}
      end
    end
  end

  def do_handle_params(_params, url, socket) do # show all my threads
    current_user = current_user(socket)

    feed = if current_user, do: if module_enabled?(Bonfire.Social.Messages), do: Bonfire.Social.Messages.list(current_user, nil, latest_in_threads: true, limit: 10) #|> debug()

    {:noreply,
    socket
    |> assign(
      page_title: l("Direct Messages"),
      page: "messages",
      feed: e(feed, :edges, []),
      tab_id: nil,
      reply_to_id: nil,
      thread_id: nil
    ) #|> IO.inspect
  }
  end

  # def handle_event("compose_thread", _ , socket) do
  #   debug("start a thread")
  #   debug(e(socket, :to_circles, []))
  #   {:noreply, assign(socket, tab_id: "select_recipients")}
  # end

  def handle_params(params, uri, socket) do
    # debug(params, "params")
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
