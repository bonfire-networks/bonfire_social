defmodule Bonfire.Social.Web.LiveHandlers.Posts do

  alias Bonfire.Common.Utils
  import Utils
  import Phoenix.LiveView

  @thread_max_depth 3 # TODO: put in config

  def handle_params(%{"cursor" => cursor} = _attrs, _, %{assigns: %{thread_id: thread_id}} = socket) do
    live_more(thread_id, cursor, socket, false)
  end

  def handle_event("feed_load_more", %{"cursor" => cursor} = _attrs, %{assigns: %{thread_id: thread_id}} = socket) do
    live_more(thread_id, cursor, socket)
  end

  def live_more(thread_id, cursor, socket, infinite_scroll \\ true) do
    # IO.inspect(pagination: cursor)

    with %{entries: replies, metadata: page_info} <- Bonfire.Social.Posts.list_replies(thread_id, e(socket, :assigns, :current_user, nil), cursor, @thread_max_depth) do

      replies = if infinite_scroll, do: e(socket.assigns, :replies, []) ++ (replies || []),
      else: replies || []

      threaded_replies = if is_list(replies) and length(replies)>0, do: Bonfire.Social.Posts.arrange_replies_tree(replies), else: []
      #IO.inspect(replies, label: "REPLIES:")

      {:noreply,
      socket
      |> Phoenix.LiveView.assign(
        replies: replies || [],
        threaded_replies: threaded_replies,
        page_info: page_info,
      )}
    end
  end

  def handle_event("post", params, socket) do
    attrs = params
    |> input_to_atoms()
    # |> IO.inspect

    with {:ok, published} <- Bonfire.Social.Posts.publish(socket.assigns.current_user, attrs) do
      #IO.inspect("published!")
      {:noreply,
        socket
        # Phoenix.LiveView.assign(socket,
        #   feed: [%{published.activity | object_post: published.post, subject_user: socket.assigns.current_user}] ++ Map.get(socket.assigns, :feed, [])
        # )
      }
    end
  end

  def handle_event("post_load_replies", %{"id" => id, "level" => level}, socket) do
    {level, _} = Integer.parse(level)
    replies = Bonfire.Social.Posts.list_replies(id, nil, level + @thread_max_depth)
    replies = replies ++ socket.assigns.replies
    {:noreply,
        assign(socket,
        replies: replies,
        threaded_replies: Bonfire.Social.Posts.arrange_replies_tree(replies) || []
    )}
  end

  def handle_event("post_reply", attrs, socket) do

    attrs = attrs |> input_to_atoms()

    with {:ok, published} <- Bonfire.Social.Posts.publish(socket.assigns.current_user, attrs) do

      # replies = [published] ++ socket.assigns.replies # TODO: replace with pubsub

      {:noreply,
        socket
        # assign(socket,
        #   replies: replies,
        #   threaded_replies: Bonfire.Social.Posts.arrange_replies_tree(replies) || []
        # )
    }
    end

  end

  def handle_event("post_follow", %{"id" => thread_id}, socket) do
    with {:ok, _follow} <- Bonfire.Social.Follows.follow(e(socket.assigns, :current_user, nil), thread_id) do
      {:noreply, assign(socket,
       following: true
     )}
    else e ->
      {:noreply, socket} # TODO: handle errors
    end
  end

  def handle_info({:post_new_reply, data}, socket) do

    # IO.inspect(post_new_reply: data)
    # IO.inspect(replies: Utils.e(socket.assigns, :replies, []))

    replies = [data] ++ Utils.e(socket.assigns, :replies, [])

    {:noreply,
        Phoenix.LiveView.assign(socket,
          replies: replies,
          # threaded_replies: Bonfire.Social.Posts.arrange_replies_tree(replies) || []
      )}
  end

end
