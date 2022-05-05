defmodule Bonfire.Social.Web.PostLive do
  use Bonfire.UI.Common.Web, :surface_view
  alias Bonfire.Me.Web.LivePlugs
  import Where

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
      page_title: l("Post"),
      page: "discussion",
      smart_input_prompt: l("Reply to this post"),
      activity: nil,
      post: nil,
      thread_id: nil,
      replies: []
    )
  }
  end

  def do_handle_params(%{"id" => id} = params, url, socket) do

    current_user = current_user(socket)

    # debug(params, "PARAMS")
    debug(url, "post url")

    with {:ok, post} <- Bonfire.Social.Posts.read(id, socket) do

      {activity, post} = Map.pop(post, :activity)
      activity = Bonfire.Social.Activities.activity_preloads(activity, :all, current_user: current_user)
      # debug(post, "the post")
      # debug(activity, "the activity")
      # following = if current_user && module_enabled?(Bonfire.Social.Follows) && Bonfire.Social.Follows.following?(current_user, post), do: [post.id]

      thread_id = e(activity, :replied, :thread_id, id)

      reply_to_id = e(params, "reply_to_id", id) #|> debug("reply_to_id")

      # smart_input_prompt = l("Reply to post:")<>" "<>text_only(e(post, :post_content, :name, e(post, :post_content, :summary, e(post, :post_content, :html_body, reply_to_id))))
      smart_input_prompt = l("Reply")

      participants = Bonfire.Social.Threads.list_participants(activity, thread_id, current_user: current_user)

      to_circles = if length(participants)>0, do: Enum.map(participants, & {e(&1, :character, :username, l "someone"), e(&1, :id, nil)})

      # names = if length(participants)>0, do: Enum.map_join(participants, ", ", &e(&1, :profile, :name, e(&1, :character, :username, l "someone else")))

      mentions = if length(participants)>0, do: Enum.map_join(participants, " ", & "@"<>e(&1, :character, :username, ""))<>" "

      {:noreply,
      socket
      |> assign(
        activity: activity,
        post: post,
        url: url,
        participants: participants,
        # following: following || []
      )
      |> assign_global(
        thread_id: e(post, :id, nil),
        # smart_input_prompt: smart_input_prompt,
        reply_to_id: reply_to_id,
        smart_input_text: mentions,
        to_circles: to_circles,
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
    with {_, socket} <- Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end

  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.UI.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
