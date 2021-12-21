defmodule Bonfire.Social.Web.MessageLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Social.Integration

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
        reply_id: nil,
        activity: nil,
        object: nil,
        thread_id: nil,
      ) #|> IO.inspect
      |> assign_global(
        search_placeholder: "Search this discussion",
        create_activity_type: "message",
        smart_input_placeholder: "Reply privately",
      )
    }
  end

  def do_handle_params(%{"id" => id} = params, _url, socket) do
   current_user = current_user(socket)

    # FIXME?
    with {:ok, post} <- Bonfire.Social.Messages.read(id, socket) do
      #IO.inspect(post, label: "the post:")

      {activity, object} = Map.pop(post, :activity)
      {preloaded_object, activity} = Map.pop(activity, :object)

      object = Map.merge(object, preloaded_object)
              |> Integration.repo().maybe_preload(:tags)
              # |> IO.inspect(label: "the message")

      # IO.inspect(activity)
      other_user = if e(activity, :subject_character, :id, nil) != e(current_user, :id, nil) && e(activity, :subject_character, :id, nil) do
        e(activity, :subject_character, nil)
      else
        if e(activity, :replied, :reply_to_created, :creator_character, :id, nil) != e(current_user, :id, nil) && e(activity, :replied, :reply_to_created, :creator_character, nil), do: e(activity, :replied, :reply_to_created, :creator_character, nil)
      end

      mention = if other_user, do: "@"<>e(other_user, :username, "")<>" "

      {:noreply,
      socket
      |> assign(
        page_title: "Private Message",
        page: "Private Message",
        has_private_tab: false,
        reply_id: Map.get(params, "reply_id"),
        activity: activity,
        object: object,
        thread_id: e(object, :id, nil),
      ) #|> IO.inspect
      |> assign_global(
        search_placeholder: "Search this discussion",
        create_activity_type: "message",
        smart_input_placeholder: "Reply privately",
        smart_input_text: mention || "",
        to_circles: [{e(other_user, :username, l "someone"), e(other_user, :id, nil)}]
      )
    }

    else _e ->
      {:error, "Not found (or you don't have permission to view this message)"}
    end
  end


  def handle_event("create_reply", %{"id"=> id}, socket) do # boost in LV
    IO.inspect(id: id)
    IO.inspect("create reply")
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
