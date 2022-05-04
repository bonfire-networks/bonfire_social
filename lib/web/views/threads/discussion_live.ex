defmodule Bonfire.Social.Web.DiscussionLive do
  use Bonfire.UI.Common.Web, :surface_view
  alias Bonfire.Me.Web.LivePlugs

  def mount(params, session, socket) do
    live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, _session, socket) do
    {:ok,
    socket
    |> assign(
      page_title: l("Discussion"),
      page: "discussion",
      has_private_tab: false,
      search_placeholder: l("Search this discussion"),
      smart_input_prompt: l("Reply to this discussion"),
    )}
  end

  def do_handle_params(%{"id" => id} = params, url, socket) do
    # FIXME: consolidate common code with PostLive and MessagesLive

    current_user = current_user(socket)
    # debug(params, "PARAMS")

    with {:ok, object} <- Bonfire.Social.Objects.read(id, socket) do

      {activity, object} = Map.pop(object, :activity)
      {preloaded_object, activity} = Map.pop(activity, :object)
      activity = Bonfire.Social.Activities.activity_preloads(activity, :all, current_user: current_user)

      thread_id = e(activity, :replied, :thread_id, id)

      # following = if current_user && module_enabled?(Bonfire.Social.Follows) do
      #   a = if Bonfire.Social.Follows.following?(current_user, object), do: object.id
      #   b = if thread_id && Bonfire.Social.Follows.following?(current_user, thread_id), do: thread_id
      #   [a, b]
      # end

      reply_to_id = e(params, "reply_to_id", id)

      participants = Bonfire.Social.Threads.list_participants(activity, thread_id, current_user: current_user)

      to_circles = if length(participants)>0, do: Enum.map(participants, & {e(&1, :character, :username, l "someone"), e(&1, :id, nil)})

      # names = if length(participants)>0, do: Enum.map_join(participants, ", ", &e(&1, :profile, :name, e(&1, :character, :username, l "someone else")))

      mentions = if length(participants)>0, do: Enum.map_join(participants, " ", & "@"<>e(&1, :character, :username, ""))<>" "

      {:noreply,
      socket
      |> assign(
        reply_to_id: reply_to_id,
        activity: activity,
        url: url,
        object: Map.merge(object, preloaded_object || %{}),
        # thread_id: e(object, :id, nil),
        # smart_input_prompt: "Reply to #{reply_to_id}",
        # smart_input_text: mentions,
        # to_circles: to_circles,
        participants: participants,
      ) |> assign_global(
        thread_id: e(object, :id, nil),
        # smart_input_prompt: smart_input_prompt,
        reply_to_id: reply_to_id,
        smart_input_text: mentions,
        to_circles: to_circles,
      ) }

    else _e ->
      {:error, l("Not found (or you don't have permission to view this)")}
    end

  end


  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <- Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end

  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.UI.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
