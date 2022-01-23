defmodule Bonfire.Social.Threads do

  @default_max_depth 3 # TODO: configurable

  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo,
    schema: Replied,
    searchable_fields: [:id, :thread_id, :reply_to_id],
    sortable_fields: [:id]

  import Bonfire.Boundaries.Queries

  alias Bonfire.Data.Social.Replied
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Boundaries.Verbs
  alias Pointers.{Pointer, ULID}

  def context_module, do: Replied
  def queries_module, do: Replied

  def maybe_push_thread(%{} = creator, %{} = activity, %{replied: %{thread_id: thread_id, reply_to_id: reply_to_id}} = _reply) when is_binary(thread_id) and is_binary(reply_to_id) do

    with {:ok, published} <- FeedActivities.maybe_feed_publish(creator, activity, thread_id) do
      Logger.debug("Threads: put in thread feed for anyone following the thread: #{inspect thread_id}")
      # IO.inspect(activity: activity)
      Logger.debug("Threads: broadcasting to anyone currently viewing the thread")
      pubsub_broadcast(thread_id, {{Bonfire.Social.Posts, :new_reply}, {thread_id, activity}})

    end
  end

  def maybe_push_thread(_, _, _), do: nil

  @doc """
  Handles casting related to the reply and threading.
  If it's not a reply or the user is not permitted to reply to the thing, a new thread will be created.
  """
  # def cast(changeset, attrs, user, "public"), do: cast_replied(changeset, attrs, user)
  # def cast(changeset, attrs, user, _), do: start_new_thread(changeset)
  def cast(changeset, attrs, user, _), do: cast_replied(changeset, attrs, user)

  defp cast_replied(changeset, attrs, user) do
    case find_reply_id(attrs) do
      reply_to when is_binary(reply_to) ->
        case load_reply(user, reply_to) do

          %{replied: %{thread_id: id}}=reply_to when is_binary(id) ->
            Logger.debug("[Threads.cast_replied/3] copying thread from responded to")
            replied = %{thread_id: id, reply_to_id: reply_to.id, replying_to: reply_to} |> debug()

            changeset
              |> do_cast_replied(replied)
              # |> Changeset.change(%{replied: replied})
              |> debug("cs with replied")

          %{}=reply_to ->
            Logger.debug("[Threads.cast_replied/3] parent has no thread, creating one")

            repo().insert_all(Replied, %{id: reply_to.id, thread_id: reply_to.id}, on_conflict: :nothing)

            do_cast_replied(changeset, %{thread_id: nil, reply_to_id: reply_to.id})
              |> put_in([:changes, :replied, :data, :reply_to, :replied], %Replied{id: reply_to.id, thread_id: reply_to.id})

          _ ->
            Logger.debug("[Threads.cast_replied/3] not permitted to reply to this, starting new thread")
            start_new_thread(changeset)
        end
      _ ->
        Logger.debug("[Threads.cast_replied/3] does not reply to anything, starting new thread")
        start_new_thread(changeset)
    end
  end

  defp do_cast_replied(changeset, attrs) do
    changeset
    |> Changeset.cast(%{replied: attrs}, [])
    |> Changeset.cast_assoc(:replied, with: &casted_changeset/2)
  end

  def casted_changeset(cs \\ %Replied{}, attrs) do
    changeset(cs, attrs)
    |> Changeset.cast(attrs, [:replying_to, :reply_to_id, :thread_id])
  end

  defp find_reply_id(%{reply_to: %{reply_to_id: id}})
  when is_binary(id) and id != "", do: id
  defp find_reply_id(_), do: nil

  # loads a reply, but only if you are allowed to reply to it.
  defp load_reply(user, id) do
    from(p in Pointer, as: :root, where: p.id == ^id)
    |> proload([:replied, created: [creator: [:character]]])
    |> boundarise(root.id, verbs: [:reply], current_user: user)
    |> repo().one()
  end

  @doc false
  def start_new_thread(changeset) do
    changeset = force_to_have_id(changeset)
    id = Changeset.get_field(changeset, :id)
    do_cast_replied(changeset, %{reply_to_id: nil, thread_id: id})
  end

  defp force_to_have_id(changeset) do
    if Changeset.get_field(changeset, :id), do: changeset,
      else: Changeset.put_change(changeset, :id, ULID.generate())
  end

  defp create(attrs) do
    repo().put(changeset(attrs))
  end

  def changeset(replied \\ %Replied{}, %{} = attrs) do
    Replied.changeset(replied, attrs)
  end

  def read(object_id, socket_or_current_user) when is_binary(object_id) do
    current_user = current_user(socket_or_current_user)
    with {:ok, object} <- Replied |> query_filter(id: object_id)
      |> Activities.read(socket_or_current_user) do

        {:ok, object}
      end
  end

  @doc "List participants in a thread (depending on user's boundaries)"
  def list_participants(thread_id, current_user \\ nil, opts \\ [], preloads \\ :minimal) when is_binary(thread_id) or is_list(thread_id) do

    FeedActivities.feed_paginated(
      [participants_in: {thread_id, &filter/3}],
      current_user, opts, preloads, Replied, false)
  end

  def filter(:participants_in, thread_id, query) do
    verb_id = Verbs.verbs()[:create]

    query
      |> join_preload([:activity, :subject_character])
      |> distinct([fp, subject_character: subject_character], [desc: subject_character.id])
      |> where(
        [replied, activity: activity, subject_character: subject_character],
        (replied.thread_id == ^thread_id  or replied.id == ^thread_id or replied.reply_to_id == ^thread_id) and activity.verb_id==^verb_id
      )
  end

  #doc "Group per-thread "
  def filter(:distinct, :threads, query) do
    query
      |> join_preload([:activity, :replied])
      |> distinct([fp, replied: replied], [desc: replied.thread_id])
  end


  def list_replies(thread, current_user, cursor \\ nil, max_depth \\ @default_max_depth, limit \\ 500)
  def list_replies(%{thread_id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(%{id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(thread_id, current_user, cursor, max_depth, limit) when is_binary(thread_id), do: do_list_replies(thread_id, current_user, cursor, max_depth, limit)

  defp do_list_replies(thread_id, current_user_or_socket, cursor, max_depth, limit) do

    pubsub_subscribe(thread_id, current_user_or_socket) # subscribe to realtime thread updates

    query([thread_id: thread_id], current_user_or_socket, max_depth)
      |> Bonfire.Repo.many_paginated(limit: limit, before: e(cursor, :before, nil), after: e(cursor, :after, nil)) # return a page of items + pagination metadata
      # |> repo().many # without pagination
      # |> IO.inspect(label: "thread")
  end

  def query(filter, current_user_or_socket, max_depth \\ @default_max_depth)

  def query([thread_id: thread_id], current_user_or_socket, max_depth) do

    current_user = current_user(current_user_or_socket)
    # IO.inspect(current_user: current_user)

    %Replied{id: Bonfire.Common.Pointers.id_binary(thread_id)}
      |> Replied.descendants()
      |> Replied.where_depth(is_smaller_than_or_equal_to: (max_depth || @default_max_depth))
      |> Activities.query_object_preload_create_activity(current_user)
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect(label: "Thread nested query")
  end

  def query(filter, current_user_or_socket, max_depth) do

    current_user = current_user(current_user_or_socket)
    # IO.inspect(current_user: current_user)

    Replied
      |> query_filter(filter)
      |> Activities.query_object_preload_create_activity(current_user)
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect(label: "Thread filtered query")
  end

  def arrange_replies_tree(replies), do: replies |> Replied.arrange() # uses https://github.com/bonfire-networks/ecto_materialized_path

  # Deprecated:
  # def arrange_replies_tree(replies) do
  #   thread = replies
  #   |> Enum.reverse()
  #   |> Enum.map(&Map.from_struct/1)
  #   |> Enum.reduce(%{}, &Map.put(&2, &1.id, &1))
  #   # |> IO.inspect

  #   do_reply_tree = fn
  #     {_id, %{reply_to_id: reply_to_id, thread_id: thread_id} =_reply} = reply_with_id,
  #     acc
  #     when is_binary(reply_to_id) and reply_to_id != thread_id ->
  #       #IO.inspect(acc: acc)
  #       #IO.inspect(reply_ok: reply)
  #       #IO.inspect(reply_to_id: reply_to_id)

  #       if Map.get(acc, reply_to_id) do

  #           acc
  #           |> put_in(
  #               [reply_to_id, :direct_replies],
  #               Bonfire.Common.Utils.maybe_get(acc[reply_to_id], :direct_replies, []) ++ [reply_with_id]
  #             )
  #           # |> IO.inspect
  #           # |> Map.delete(id)

  #       else
  #         acc
  #       end

  #     reply, acc ->
  #       #IO.inspect(reply_skip: reply)

  #       acc
  #   end

  #   Enum.reduce(thread, thread, do_reply_tree)
  #   |> Enum.reduce(thread, do_reply_tree)
  #   # |> IO.inspect
  #   |> Enum.reduce(%{}, fn

  #     {id, %{reply_to_id: reply_to_id, thread_id: thread_id} =reply} = reply_with_id, acc when not is_binary(reply_to_id) or reply_to_id == thread_id ->

  #       acc |> Map.put(id, reply)

  #     reply, acc ->

  #       acc

  #   end)
  # end

  # def get_feed_id(%

end
