defmodule Bonfire.Social.Web.DiscussionLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs

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
      page_title: "Discussion",
      page: "Discussion",
      has_private_tab: false,
      search_placeholder: "Search this discussion",
      smart_input_prompt: "Reply to this discussion",
    )}
  end

  def do_handle_params(%{"id" => id} = params, _url, socket) do
    # FIXME: consolidate common code with PostLive and MessageLive

    current_user = current_user(socket)

    # debug(params, "PARAMS")

    with {:ok, object} <- Bonfire.Social.Objects.read(id, socket) do

      {activity, object} = Map.pop(object, :activity)
      {preloaded_object, activity} = Map.pop(activity, :object)

      # following = if current_user && module_enabled?(Bonfire.Social.Follows) do
      #   a = if Bonfire.Social.Follows.following?(current_user, object), do: object.id
      #   thread_id = e(activity, :replied, :thread_id, nil)
      #   b = if thread_id && Bonfire.Social.Follows.following?(current_user, thread_id), do: thread_id
      #   [a, b]
      # end

      reply_to_id = e(params, "reply_to_id", id)

      other_characters = if e(activity, :subject, :character, nil) && e(activity, :subject, :id, nil) != e(current_user, :id, nil) do
        [e(activity, :subject, :character, nil)]
      end

      mentions = if other_characters, do: Enum.map_join(other_characters, " ", & "@"<>e(&1, :username, ""))<>" "

      {:noreply,
      socket
      |> assign(
        reply_to_id: reply_to_id,
        activity: activity,
        object: Map.merge(object, preloaded_object || %{}),
        thread_id: e(object, :id, nil),
        smart_input_prompt: "Reply to #{reply_to_id}",
        smart_input_text: mentions || "",
      )}

    else _e ->
      {:error, "Not found (or you don't have permission to view this)"}
    end

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
