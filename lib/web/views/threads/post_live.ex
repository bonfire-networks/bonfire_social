defmodule Bonfire.Social.Web.PostLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs
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

  def do_handle_params(%{"id" => id} = params, url, socket) do

    current_user = current_user(socket)

    # debug(params, "PARAMS")
    debug(url, "post url")

    with {:ok, post} <- Bonfire.Social.Posts.read(id, socket) do

      {activity, post} = Map.pop(post, :activity)
      # debug(post, "the post")
      # debug(activity, "the activity")
      # following = if current_user && module_enabled?(Bonfire.Social.Follows) && Bonfire.Social.Follows.following?(current_user, post), do: [post.id]

      reply_to_id = e(params, "reply_to_id", id) #|> debug("reply_to_id")

      # smart_input_prompt = l("Reply to post:")<>" "<>text_only(e(post, :post_content, :name, e(post, :post_content, :summary, e(post, :post_content, :html_body, reply_to_id))))
      smart_input_prompt = l("Reply")

      subject_character = e(activity, :subject, :character, nil) || e(post, :created, :creator, :character, nil)
      # debug(subject_character, "the subject_character")

      # TODO: add other already mentioned in the post we're replying to
      other_characters = if subject_character && e(subject_character, :id, nil) != e(current_user, :id, nil) do
        [subject_character]
      end

      mentions = if other_characters, do: Enum.map_join(other_characters, " ", & "@"<>e(&1, :username, ""))<>" " #|> info("mentions")

      {:noreply,
      socket
      |> assign(
        activity: activity,
        post: post,
        url: url,
        # following: following || []
      )
      |> assign_global(
        thread_id: e(post, :id, nil),
        # smart_input_prompt: smart_input_prompt,
        reply_to_id: reply_to_id,
        smart_input_text: mentions,
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
