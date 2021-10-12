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

    current_user = current_user(socket)

    with {:ok, object} <- Bonfire.Social.Objects.read(Map.get(params, "id"), socket) do

      {activity, object} = Map.pop(object, :activity)
      {preloaded_object, activity} = Map.pop(activity, :object)

      # IO.inspect(object, label: "the object:")
      # IO.inspect(activity, label: "the activity:")

      # following = if current_user && module_enabled?(Bonfire.Social.Follows) do
      #   a = if Bonfire.Social.Follows.following?(current_user, object), do: object.id
      #   thread_id = e(activity, :replied, :thread_id, nil)
      #   b = if thread_id && Bonfire.Social.Follows.following?(current_user, thread_id), do: thread_id
      #   [a, b]
      # end

      {:ok,
      socket
      |> assign(
        page_title: "Discussion",
        page: "Discussion",
        has_private_tab: false,
        search_placeholder: "Search this discussion",
        smart_input_placeholder: "Reply to the discussion",
        reply_id: Map.get(params, "reply_id"),
        activity: activity,
        object: Map.merge(object, preloaded_object || %{}),
        thread_id: e(object, :id, nil),
      )}

    else _e ->
      {:error, "Not found"}
    end


  end

  # def handle_params(%{"tab" => tab} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      selected_tab: tab
  #    )}
  # end

  # def handle_params(%{} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      current_user: Fake.user_live()
  #    )}
  # end


  defdelegate handle_params(params, attrs, socket), to: Bonfire.Common.LiveHandlers
  def handle_event(action, attrs, socket), do: Bonfire.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
