defmodule Bonfire.Social.Threads do

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

  @doc """
  Handles casting related to the reply and threading.
  If it's not a reply or the user is not permitted to reply to the thing, a new thread will be created.
  """
  # def cast(changeset, attrs, user, "public"), do: cast_replied(changeset, attrs, user)
  # def cast(changeset, attrs, user, _), do: start_new_thread(changeset)
  def cast(changeset, attrs, user, _preset_or_custom_boundary), do: cast_replied(changeset, attrs, user)

  defp cast_replied(changeset, attrs, user) do

    custom_thread_id = find_thread_id(attrs) |> load_thread_id(user, ...) # for forking threads

    case find_reply_id(attrs) do
      reply_to when is_binary(reply_to) ->
        case load_reply_to(user, reply_to) do

          %{replied: %{thread_id: thread_id}}=reply_to when is_binary(thread_id) ->
            debug("[Threads.cast_replied/3] copying thread from reply_to")

            # reply to the thread if we're allowed to (or a custom one if specified)
            thread_id = custom_thread_id || load_thread_id(user, thread_id) || reply_to.id

            replied = %{thread_id: thread_id, reply_to: reply_to} #|> debug()
              |> do_cast_replied(changeset, ...)
              # |> Changeset.change(%{replied: replied})
              # |> debug("cs with replied")

          %{}=reply_to ->
            debug("[Threads.cast_replied/3] parent has no thread, creating one")

            repo().upsert(changeset(%{id: reply_to.id, thread_id: reply_to.id}))

            thread_id = custom_thread_id || reply_to.id


            do_cast_replied(changeset, %{thread_id: thread_id, reply_to: reply_to})
              |> put_in( # FIXME: function Ecto.Changeset.get_and_update/3 is undefined (Ecto.Changeset does not implement the Access behaviour)
                [:changes, :replied, :data, :reply_to, :replied],
                %Replied{id: reply_to.id, thread_id: thread_id}
              )

          _ ->
            debug("[Threads.cast_replied/3] not permitted to reply to this, starting new thread")
            start_new_thread(changeset)
        end
      _ ->
        debug("[Threads.cast_replied/3] does not reply to anything, starting new thread")
        start_new_thread(changeset)
    end
  end

  defp do_cast_replied(changeset, attrs) do
    # debug(attrs)
    changeset
    |> Changeset.cast(%{replied: attrs}, [])
    # |> debug()
    |> Changeset.cast_assoc(:replied, with: &changeset_casted/2)
  end

  defp changeset_casted(cs \\ %Replied{}, attrs) do
    # debug(attrs)
    changeset(cs, attrs)
    |> Changeset.cast(Map.put(attrs, :replying_to, attrs[:reply_to]), [:replying_to]) # ugly hack to pass the data along so it can be used by Acls.cast and Feeds.target_feeds
  end

  def changeset(replied \\ %Replied{}, %{} = attrs) do
    Replied.changeset(replied, attrs)
  end

  defp find_reply_id(%{reply_to_id: id}) when is_binary(id) and id != "", do: id
  defp find_reply_id(%{reply_to: attrs}), do: find_reply_id(attrs)
  defp find_reply_id(_), do: nil

  defp find_thread_id(%{thread_id: id}) when is_binary(id) and id != "", do: id
  defp find_thread_id(%{reply_to: attrs}), do: find_thread_id(attrs)
  defp find_thread_id(_), do: nil

  # loads a reply, but only if you are allowed to reply to it.
  defp load_reply_to(user, id) do
    from(p in Pointer, as: :root, where: p.id == ^id)
    |> proload([:replied, created: [creator: [:character]]])
    |> boundarise(root.id, verbs: [:reply], current_user: user)
    |> repo().one()
  end

  defp load_thread_id(user, id) when is_binary(id) do
    from(p in Pointer, as: :root, where: p.id == ^id)
    |> proload([:replied])
    |> boundarise(root.id, verbs: [:reply], current_user: user)
    |> repo().one()
    |> e(:id, nil)
  end
  defp load_thread_id(user, _), do: nil

  @doc false
  def start_new_thread(changeset) do
    # changeset = force_to_have_id(changeset) # FIXME?
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
    verb_id = Verbs.get_id!(:create)

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


  def list_replies(thread, opts \\ [])
  def list_replies(%{thread_id: thread_id}, opts), do: list_replies(thread_id, opts)
  def list_replies(%{id: thread_id}, opts), do: list_replies(thread_id, opts)
  def list_replies(thread_id, opts) when is_binary(thread_id) do
    opts =
      to_options(opts)
      |> Keyword.put_new(:limit, Config.get(:thread_default_pagination_limit, 500))

    pubsub_subscribe(thread_id, opts) # subscribe to realtime thread updates

    query(
      [thread_id: thread_id], # note this won't query by thread_id but rather by path
      opts
    )
      # |> debug()
      |> Bonfire.Repo.many_paginated(opts) # return a page of items + pagination metadata
      # |> repo().many # without pagination
      # |> debug("thread")
  end

  def query([thread_id: thread_id], opts) do
    opts =
      to_options(opts)
      |> Keyword.put_new(:max_depth, Config.get(:thread_default_max_depth, 3))

    current_user = current_user(opts)

    %Replied{id: Bonfire.Common.Pointers.id_binary(thread_id)}
      |> Replied.descendants()
      |> Replied.where_depth(is_smaller_than_or_equal_to: opts[:max_depth])
      |> Activities.query_object_preload_create_activity(current_user)
      |> Activities.as_permitted_for(current_user, [:see])
      # |> debug("Thread nested query")
  end

  def query(filter, opts) do

    current_user = current_user(opts)

    Replied
      |> query_filter(filter)
      |> Activities.query_object_preload_create_activity(current_user)
      |> Activities.as_permitted_for(current_user, [:see])
      # |> debug("Thread filtered query")
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
  #       #debug(acc: acc)
  #       #debug(reply_ok: reply)
  #       #debug(reply_to_id: reply_to_id)

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
  #       #debug(reply_skip: reply)

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
