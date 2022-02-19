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
      smart_input_prompt: "Reply to this post",
      has_private_tab: false,
      activity: nil,
      post: nil,
      thread_id: nil,
      replies: []
    )
  }
  end

  def do_handle_params(%{"id" => id} = params, _url, socket) do

    current_user = current_user(socket)

    debug(params, label: "PARAMS")

    with {:ok, post} <- Bonfire.Social.Posts.read(id, socket) do
      # debug(post, label: "the post:")

      {activity, post} = Map.pop(post, :activity)
      # following = if current_user && module_enabled?(Bonfire.Social.Follows) && Bonfire.Social.Follows.following?(current_user, post), do: [post.id]

      reply_to_id = e(params, "reply_to_id", id) #|> debug("reply_to_id")

      other_characters = if e(activity, :subject, :character, nil) && e(activity, :subject, :id, nil) != e(current_user, :id, nil) do
        [e(activity, :subject, :character, nil)]
      end

      mentions = if other_characters, do: Enum.map_join(other_characters, " ", & "@"<>e(&1, :username, ""))<>" " |> debug()

      {:noreply,
      socket
      |> assign(
        activity: activity,
        post: post,
        # following: following || []
      )
      |> assign_global(
        thread_id: e(post, :id, nil),
        smart_input_prompt: "Reply to post #{reply_to_id}",
        reply_to_id: reply_to_id,
        smart_input_text: mentions || "",
      )
      }

    else _e ->
      {:error, "Not found"}
    end

  end

  def do_handle_params(_params, _url, socket) do
    {:noreply,
      socket
      |> push_redirect(to: path(:write))
    }
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
