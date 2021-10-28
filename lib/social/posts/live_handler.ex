defmodule Bonfire.Social.Posts.LiveHandler do
  use Bonfire.Web, :live_handler
  require Logger

  alias Bonfire.Social.Posts
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Data.Social.Post
  alias Ecto.Changeset

  @thread_max_depth 3 # TODO: put in config

  def merge_child(%{} = map, key) do
    map
    |> Map.merge(
      Map.get(map, key)
    )
  end

  def handle_params(%{"after" => cursor} = _attrs, _, %{assigns: %{thread_id: thread_id}} = socket) do
    live_more(thread_id, cursor, socket)
  end

  def handle_event("load_more", %{"after" => cursor} = _attrs, %{assigns: %{thread_id: thread_id}} = socket) do
    live_more(thread_id, cursor, socket)
  end

  def handle_event("post", %{"create_activity_type"=>"message"}=params, socket) do
    Bonfire.Social.Messages.LiveHandler.send_message(params, socket)
  end

  def handle_event("post", %{"post" => %{"create_activity_type"=>"message"}}=params, socket) do
    Bonfire.Social.Messages.LiveHandler.send_message(params, socket)
  end


  def handle_event("post", params, socket) do # if not a message, it's a post by default
    attrs = params
    |> input_to_atoms()
    # |> IO.inspect

    with %{valid?: true} <- post_changeset(attrs),
         {:ok, _published} <- Bonfire.Social.Posts.publish(current_user(socket), attrs, params["boundary_selected"]) do
      # IO.inspect("published!")
      {:noreply,
        socket
        |> put_flash(:info, "Posted!")

        # Phoenix.LiveView.assign(socket,
        #   feed: [%{published.activity | object_post: published.post, subject_user: current_user(socket)}] ++ Map.get(socket.assigns, :feed, [])
        # )
      }
    end
  end

  def handle_event("load_replies", %{"id" => id, "level" => level}, socket) do
    {level, _} = Integer.parse(level)
    %{entries: replies} = Bonfire.Social.Threads.list_replies(id, socket, level + 1)
    replies = replies ++ Utils.e(socket.assigns, :replies, [])
    {:noreply,
        assign(socket,
        replies: replies
        # threaded_replies: Bonfire.Social.Threads.arrange_replies_tree(replies) || []
    )}
  end


  def handle_event("input", %{"circles" => selected_circles} = _attrs, socket) when is_list(selected_circles) and length(selected_circles)>0 do

    previous_circles = e(socket, :assigns, :to_circles, []) #|> Enum.uniq()

    new_circles = Bonfire.Me.Web.LiveHandlers.Boundaries.set_circles(selected_circles, previous_circles)

    {:noreply,
        socket
        |> assign(
          to_circles: new_circles
        )
    }
  end

  def handle_event("input", _attrs, socket) do # no circle
    {:noreply,
      socket
        |> assign(
          to_circles: []
        )
    }
  end

  def handle_info({:new_reply, {thread_id, data}}, socket) do

    Logger.info("Bonfire.Social.Posts handle_info received :new_reply")
    # IO.inspect(replies: Utils.e(socket.assigns, :replies, []))

    # replies = [data] ++ Utils.e(socket.assigns, :replies, [])

    send_update(Bonfire.UI.Social.ThreadLive, id: thread_id, new_reply: data)

    {:noreply, socket}
  end


  def live_more(thread_id, cursor, socket) do
    # IO.inspect(pagination: cursor)

    with %{entries: replies, metadata: page_info} <- Bonfire.Social.Threads.list_replies(thread_id, socket, cursor, @thread_max_depth) do

      replies = ( e(socket.assigns, :replies, []) ++ (replies || []) ) |> Enum.uniq()
      # IO.inspect(replies, label: "REPLIES:")

      threaded_replies = if is_list(replies) and length(replies)>0, do: Bonfire.Social.Threads.arrange_replies_tree(replies), else: []
      # IO.inspect(threaded_replies, label: "REPLIES threaded")

      new = [
        replies: replies || [],
        threaded_replies: threaded_replies,
        page_info: page_info
      ]

      {:noreply, socket |> assign(new)}
    end
  end


  def post_changeset(attrs \\ %{}) do
    Posts.changeset(:create, attrs)
    |> Changeset.cast_assoc(:post_content, [:required, with: &post_content_changeset/2])
    # |> IO.inspect
  end

  def post_content_changeset(%PostContent{} = cs \\ %PostContent{}, attrs) do
    PostContents.changeset(cs, attrs)
    # |> Changeset.validate_required(:name)
  end


end
