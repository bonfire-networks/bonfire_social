defmodule Bonfire.Social.Web.LiveHandlers.Posts do

  alias Bonfire.Common.Utils
  alias Bonfire.Social.Posts
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Data.Social.Post
  alias Ecto.Changeset
  import Utils
  import Phoenix.LiveView

  @thread_max_depth 3 # TODO: put in config

  def handle_params(%{"cursor" => cursor} = _attrs, _, %{assigns: %{thread_id: thread_id}} = socket) do
    live_more(thread_id, cursor, socket, false)
  end

  def handle_event("feed_load_more", %{"cursor" => cursor} = _attrs, %{assigns: %{thread_id: thread_id}} = socket) do
    live_more(thread_id, cursor, socket)
  end

  def handle_event("post", %{"create_activity_type"=>"message"}=params, socket) do
    attrs = params
    |> input_to_atoms()
    |> IO.inspect

    with {:ok, _sent} <- Bonfire.Social.Messages.send(socket.assigns.current_user, attrs) do
      IO.inspect("sent!")
      {:noreply,
        socket
        |> put_flash(:info, "Sent!")
      }
    else e ->
      IO.inspect(message_error: e)
      {:noreply,
        socket
        |> put_flash(:error, "Could not send...")
      }
    end
  end

  def handle_event("post", params, socket) do # if not message, it's a post by default
    attrs = params
    |> input_to_atoms()
    |> IO.inspect

    with %{valid?: true} <- post_changeset(attrs),
         {:ok, _published} <- Bonfire.Social.Posts.publish(socket.assigns.current_user, attrs) do
      IO.inspect("published!")
      {:noreply,
        socket
        |> put_flash(:info, "Posted!")

        # Phoenix.LiveView.assign(socket,
        #   feed: [%{published.activity | object_post: published.post, subject_user: socket.assigns.current_user}] ++ Map.get(socket.assigns, :feed, [])
        # )
      }
    end
  end

  def handle_event("post_load_replies", %{"id" => id, "level" => level}, socket) do
    {level, _} = Integer.parse(level)
    %{entries: replies} = Bonfire.Social.Threads.list_replies(id, nil, level + 1)
    replies = replies ++ Utils.e(socket.assigns, :replies, [])
    {:noreply,
        assign(socket,
        replies: replies
        # threaded_replies: Bonfire.Social.Threads.arrange_replies_tree(replies) || []
    )}
  end


  def handle_event("post_input", %{"circles" => selected_circles} = _attrs, socket) when is_list(selected_circles) and length(selected_circles)>0 do

    previous_circles = e(socket, :assigns, :to_circles, []) #|> Enum.uniq()

    new_circles = Bonfire.Me.Web.LiveHandlers.Boundaries.set_circles(selected_circles, previous_circles)

    {:noreply,
        socket
        |> assign(
          to_circles: new_circles
        )
    }
  end

  def handle_event("post_input", _attrs, socket) do # no circle
    {:noreply,
      socket
        |> assign(
          to_circles: []
        )
    }
  end

  def handle_info({:post_new_reply, data}, socket) do

    # IO.inspect(received_post_new_reply: data)
    # IO.inspect(replies: Utils.e(socket.assigns, :replies, []))

    replies = [data] ++ Utils.e(socket.assigns, :replies, [])

    {:noreply,
        Phoenix.LiveView.assign(socket,
          replies: replies
          # threaded_replies: Bonfire.Social.Threads.arrange_replies_tree(replies) || []
      )}
  end


  def live_more(thread_id, cursor, socket, infinite_scroll \\ true) do
    # IO.inspect(pagination: cursor)

    with %{entries: replies, metadata: page_info} <- Bonfire.Social.Threads.list_replies(thread_id, e(socket, :assigns, :current_user, nil), cursor, @thread_max_depth) do

      replies = if infinite_scroll, do: e(socket.assigns, :replies, []) ++ (replies || []),
      else: replies || []

      threaded_replies = if is_list(replies) and length(replies)>0, do: Bonfire.Social.Threads.arrange_replies_tree(replies), else: []
      #IO.inspect(replies, label: "REPLIES:")

      {:noreply,
      socket
      |> Phoenix.LiveView.assign(
        replies: replies || [],
        threaded_replies: threaded_replies,
        page_info: page_info
      )}
    end
  end


  def post_changeset(%Post{} = cs \\ %Post{}, attrs) do
    Posts.changeset(:create, attrs)
    |> Changeset.cast_assoc(:post_content, [:required, with: &post_content_changeset/2])
    |> IO.inspect
  end

  def post_content_changeset(%PostContent{} = cs \\ %PostContent{}, attrs) do
    PostContents.changeset(cs, attrs)
    # |> Changeset.validate_required(:name)
  end

end
