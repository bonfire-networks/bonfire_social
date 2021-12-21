defmodule Bonfire.Social.Web.PostLive do
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
      page_title: "Post",
      page: "Discussion",
      smart_input_placeholder: "Reply to the discussion",
      has_private_tab: false,
      reply_id: nil,
      activity: nil,
      post: nil,
      thread_id: nil,
      replies: []
    )}
  end

  def do_handle_params(%{"id" => id} = _params, _url, socket) do

    current_user = current_user(socket)

    # IO.inspect(params, label: "PARAMS")

    with {:ok, post} <- Bonfire.Social.Posts.read(id, socket) do
      # IO.inspect(post, label: "the post:")

      {activity, post} = Map.pop(post, :activity)
      # following = if current_user && module_enabled?(Bonfire.Social.Follows) && Bonfire.Social.Follows.following?(current_user, post), do: [post.id]

      {:noreply,
      socket
      |> assign(
        reply_id: id,
        activity: activity,
        post: post,
        thread_id: e(post, :id, nil),
        # following: following || []
      )}

    else _e ->
      {:error, "Not found"}
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
