defmodule Bonfire.Social.Web.MessageLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Social.Integration
  import Where

  def mount(params, session, socket) do
    LivePlugs.live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
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
        page_title: "Private Message",
        page: "Private Message",
        has_private_tab: false,
        reply_to_id: nil,
        activity: nil,
        object: nil,
        thread_id: nil,
      ) #|> IO.inspect
      |> assign_global(
        search_placeholder: "Search this discussion",
        create_activity_type: :message,
        smart_input_prompt: "Reply to this message",
      )
    }
  end

  def do_handle_params(%{"id" => id} = params, _url, socket) do
   current_user = current_user(socket)

    # FIXME?
    with {:ok, post} <- Bonfire.Social.Messages.read(id, socket) do
      #debug(post, label: "the post:")

      {activity, object} = Map.pop(post, :activity)
      {preloaded_object, activity} = Map.pop(activity, :object)

      object = Map.merge(object, preloaded_object)
              |> Integration.repo().maybe_preload(tags: [:character])
              |> debug("the message")

      # debug(activity, "activity")

      other_characters = if e(activity, :subject, :character, nil) && e(activity, :subject, :id, nil) != e(current_user, :id, nil) do
        [e(activity, :subject, :character, nil)]
      else
        if e(object, :tags, nil), do: Enum.map(e(object, :tags, []), &e(&1, :character, nil))
      end

      mentions = if other_characters, do: Enum.map_join(other_characters, " ", & "@"<>e(&1, :username, ""))<>" "

      to_circles = if other_characters, do: Enum.map(other_characters, & {e(&1, :username, l "someone"), e(&1, :id, nil)})

      reply_to_id = e(params, "reply_to_id", id)

      {:noreply,
      socket
      |> assign(
        page_title: "Private Message",
        page: "Private Message",
        has_private_tab: false,
        reply_to_id: reply_to_id,
        smart_input_prompt: "Reply to message #{reply_to_id}",
        activity: activity,
        object: object,
        thread_id: e(object, :id, nil),
      ) #|> IO.inspect
      |> assign_global(
        smart_input_text: mentions || "",
        to_circles: to_circles || []
      )
    }

    else _e ->
      {:error, "Not found (or you don't have permission to view this message)"}
    end
  end


  def handle_event("create_reply", %{"id"=> id}, socket) do # boost in LV
    debug(id: id)
    debug("create reply")
    # with {:ok, _boost} <- Bonfire.Social.Boosts.boost(current_user(socket), id) do
    #   {:noreply, Phoenix.LiveView.assign(socket,
    #   boosted: Map.get(socket.assigns, :boosted, []) ++ [{id, true}]
    # )}
    # end
    {:noreply, assign(socket, comment_reply_to_id: id)}
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
