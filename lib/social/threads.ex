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
  alias Pointers.{Changesets, Pointer, ULID}

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
    custom_thread = find_thread(attrs, user)
    case find_reply_to(attrs, user) do
      {:ok, %{replied: %{thread_id: thread_id, thread: %{}}}=reply_to} ->
        thread_id = ulid(custom_thread) || thread_id
        debug(thread_id, "threading under the reply_to's thread (or using custom thread if specified)")
        changeset
        |> make_threaded(thread_id, reply_to)
        # |> debug("cs with replied")
      {:ok, %{replied: %{thread_id: thread_id}}=reply_to} when is_binary(thread_id) ->
        thread_id = ulid(custom_thread) || reply_to.id
        debug(thread_id, "we're permitted to reply to the thing, but not the thread root, so use either custom thread or use the thing we're replying to as new thread")
        changeset
        |> make_threaded(thread_id, reply_to)
      {:ok, %{}=reply_to} ->
        # debug(reply_to)
        thread_id = ulid(custom_thread) || reply_to.id
        debug(thread_id, "parent has no thread, creating one (or using custom thread if specified)")
        replied_attrs = %{id: reply_to.id, thread_id: reply_to.id}
        # pretend the replied already exists, because it will in a moment
        replied = Changesets.set_state(struct(Replied, replied_attrs), :loaded)
        reply_to = Map.put(reply_to, :replied, replied)
        changeset
        |> Changeset.prepare_changes(&create_parent_replied(&1, replied, replied_attrs))
        |> make_threaded(thread_id, reply_to)
        # |> put_in([:changes, :replied, :data, :reply_to, :replied], replied) # FIXME?
      nil ->
        if custom_thread do
          debug(custom_thread, "adding under thread but not as a reply")
          changeset
          |> Changesets.put_assoc(:replied, %{thread_id: ulid(custom_thread)})
        else
          debug("no valid reply_to_id or thread_id specified, starting new thread")
          start_new_thread(changeset)
        end
    end
  end

  @doc """
  Returns `{:ok, reply}` or `{:error, reason}`, where `reason` may be:
  * `:not_found` - we could not find the object you are replying to.
  * `:not_permitted` - you do not have permission to reply to this.
  """
  def find_reply_to(attrs, user) do
    find_reply_id(attrs)
    |> maybe_replyable(user)
  end

  # old; not sure this is what forks will look like when we implement thread forking
  defp find_thread(attrs, user) do
    find_thread_id(attrs)
    |> maybe_replyable(user)
  end

  defp maybe_replyable(id, user) do
    if is_binary(id) do
      case load_replyable(user, id) do
        %{}=reply -> {:ok, reply}
        _ ->
          error(id, "not permitted to reply to")
          nil
      end
    else
      nil
    end
  end

  @doc false
  def create_parent_replied(changeset, replied, replied_attrs) do
    changeset.repo.insert_all(Replied, [replied_attrs], on_conflict: :nothing)
    changeset
    |> Changesets.update_data(&Map.put(&1, :replied, replied))
  end

  defp start_new_thread(changeset) do
    Changeset.get_field(changeset, :id)
    |> Changesets.put_assoc(changeset, :replied, %{reply_to_id: nil, thread_id: ...})
  end

  defp make_threaded(changeset, thread, reply_to) do
    changeset
    |> Changesets.put_assoc(:replied, make_child_of(reply_to, %{thread_id: ulid(thread), reply_to: reply_to}))
  end

  defp make_child_of(reply_to = %{ id: id }, attrs) do
    #  Reimplementation of a function from EctoMaterializedPath to work with our nested changesets
    (
      Map.get(reply_to, :path, [])
      ++ [id]
    ) |> Map.put(attrs, :path, ...)
  end

  # defp do_cast_replied(changeset, attrs) do
  #   # debug(attrs)
  #   changeset
  #   |> Changeset.cast(%{replied: attrs}, [])
  #   # |> debug()
  #   |> Changeset.cast_assoc(:replied, with: &changeset_casted/2)
  # end

  # defp changeset_casted(cs \\ %Replied{}, attrs) do
  #   # debug(attrs)
  #   changeset(cs, attrs)
  #   |> Changeset.cast(Map.put(attrs, :replying_to, attrs[:reply_to]), [:replying_to]) # ugly hack to pass the data along so it can be used by Acls.cast and Feeds.target_feeds
  # end

  def changeset(replied \\ %Replied{}, %{} = attrs) do
    Replied.changeset(replied, attrs)
  end

  defp find_reply_id(%{reply_to_id: id}) when is_binary(id) and id != "", do: id
  defp find_reply_id(%{reply_to: attrs}), do: find_reply_id(attrs)
  # defp find_reply_id(%{thread_id: id}) when is_binary(id) and id != "", do: id
  defp find_reply_id(_), do: nil

  defp find_thread_id(%{thread_id: id}) when is_binary(id) and id != "", do: id
  defp find_thread_id(%{reply_to: attrs}), do: find_thread_id(attrs)
  defp find_thread_id(_), do: nil

  # loads a reply, but only if you are allowed to reply to it.
  defp load_replyable(user, id) do
    from(p in Pointer, as: :root, where: p.id == ^id)
    # load the reply_to's Replied and in particular its thread and that creator
    |> proload([replied: [thread: [created: [creator: [:character, :peered]]]]])
    |> proload([created: [creator: [:character, :peered]]])
    |> boundarise(root.id, verbs: [:reply], current_user: user)
    # |> boundarise(thread.id, verbs: [:reply], current_user: user) # FIMXE: including this fails when parent has no thread_id
    |> repo().one()
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
  def list_participants(thread_id, opts \\ []) when is_binary(thread_id) or is_list(thread_id) do
    opts = to_options(opts)

    FeedActivities.feed_paginated(
      [participants_in: {thread_id, &filter/3}],
      opts ++ [preload: :minimal],
      Replied)
  end

  def filter(:participants_in, thread_id, query) when not is_list(thread_id), do: filter(:participants_in, [thread_id], query)

  def filter(:participants_in, thread_ids, query) do
    verb_id = Verbs.get_id!(:create)

    query
      |> distinct([fp, subject_character: subject_character], [desc: subject_character.id])
      |> where(
        [replied, activity: activity],
        activity.verb_id==^verb_id
        and (
          replied.thread_id in ^thread_ids
          or replied.id in ^thread_ids
          or replied.reply_to_id in ^thread_ids)
      )
  end

  @doc "Group per-thread "
  def filter(:distinct, :threads, query) do
    query
    # |> join_preload([:activity, :replied])
    # |> order_by([root], [desc: root.id])
    |> distinct([activity: activity, replied: replied], desc: activity.id, desc: replied.thread_id)
  end

  @doc "re-order distinct threads after DISTINCT ON ordered them by thread_id - Note: this results in (Ecto.QueryError) cannot preload associations in subquery in query"
  def maybe_re_order_with_subquery(query, opts)  do #
    if opts[:latest_in_threads], do: (from all in subquery(query), order_by: all.id), else: query
  end

  @doc "re-order distinct threads after DISTINCT ON ordered them by thread_id - Note: does not support pagination"
  def maybe_re_order_result(%{edges: list} = result, opts) do
    if opts[:latest_in_threads], do: Map.put(result, :edges, Enum.sort_by(list, fn(i) -> i.id end, :desc)), else: result
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
      |> Keyword.put_new(:preload, [:default] ++ (if opts[:thread_mode]==:flat, do: [:with_parents], else: []))

    %Replied{id: Bonfire.Common.Pointers.id_binary(thread_id)}
      |> Replied.descendants()
      |> maybe_max_depth(opts[:max_depth])
      |> or_where([replied], replied.thread_id == ^thread_id or replied.reply_to_id == ^thread_id)
      |> where([replied], replied.id != ^thread_id)
      |> Activities.query_object_preload_create_activity(opts)
      # |> Activities.as_permitted_for(opts, [:see, :read])
      |> if opts[:reverse_order] do
        order_by(..., [root], root.id)
      else
        ...
      end
      |> debug("Thread nested query")
  end

  def query(filter, opts) do

    Replied
      |> query_filter(filter)
      |> Activities.query_object_preload_create_activity(opts)
      |> Activities.as_permitted_for(opts, [:see])
      # |> debug("Thread filtered query")
  end

  defp maybe_max_depth(query, max_depth) when is_integer(max_depth) do
    query
    |> Replied.where_depth(is_smaller_than_or_equal_to: max_depth)
  end
  defp maybe_max_depth(query, _max_depth), do: query

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

end
