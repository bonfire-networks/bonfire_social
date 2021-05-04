defmodule Bonfire.Social.Threads do

  alias Bonfire.Data.Social.Replied
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Utils
  # import Bonfire.Common.Hooks

  use Bonfire.Repo.Query,
    schema: Replied,
    searchable_fields: [:id, :thread_id, :reply_to_id],
    sortable_fields: [:id]


  def maybe_push_thread(%{} = creator, %{} = activity, %{replied: %{thread_id: thread_id, reply_to_id: reply_to_id}} = _reply) when is_binary(thread_id) and is_binary(reply_to_id) do

    with {:ok, published} <- FeedActivities.maybe_notify(creator, activity, thread_id) do #|> IO.inspect # push to user following the thread

      Utils.pubsub_broadcast(thread_id, {:post_new_reply, published}) # push to users viewing the thread
    end
  end

  def maybe_push_thread(_, _, _), do: nil


  def maybe_reply(%{reply_to: reply_attrs}), do: maybe_reply(reply_attrs)
  def maybe_reply(%{reply_to_id: reply_to_id} = reply_attrs) when is_binary(reply_to_id) and reply_to_id !="" do
     with {:ok, r} <- get_replied(reply_to_id) |> IO.inspect do
      Map.merge(reply_attrs, %{reply_to: r})
     else _ ->
      with {:ok, r} <- create_for_object(%{id: reply_to_id}) do
        Map.merge(reply_attrs, %{reply_to: r})
      else _ ->
         Map.drop(reply_attrs, [:reply_to_id])
        |> maybe_reply()
      end
     end
  end
  def maybe_reply(%{} = reply_attrs), do: Map.merge(reply_attrs, maybe_reply(nil))
  def maybe_reply(_), do: %{set: true} # makes sure a Replied entry is inserted even for first posts


  def get_replied(id) do
    # Bonfire.Common.Pointers.get(id)
    repo().single(from p in Replied, where: p.id == ^id)
  end

  def create_for_object(%{id: id}=_thing) do
    create(%{id: id})
  end

  defp create(attrs) do
    repo().put(changeset(attrs))
  end

  def changeset(replied \\ %Replied{}, %{} = attrs) do
    Replied.changeset(replied, attrs)
  end

  def read(object_id, socket_or_current_user) when is_binary(object_id) do

    current_user = Utils.current_user(socket_or_current_user)

    with {:ok, object} <- build_query(id: object_id)
      |> Activities.read(socket_or_current_user) do

        {:ok, object}
      end
  end

  @doc "List participants in a thread (depending on user's boundaries)"
  def list_participants(thread_id, current_user \\ nil, cursor_before \\ nil, preloads \\ :minimal) when is_binary(thread_id) or is_list(thread_id) do

    build_query(participants_in: thread_id)
    |> FeedActivities.feed_query_paginated(current_user, cursor_before, preloads)
  end

  def filter(:participants_in, thread_id, query) do
    verb_id = Verbs.verbs()[:create]

    {
      query
      |> join_preload([:activity, :subject_character])
      |> distinct([fp, subject_character: subject_character], [desc: subject_character.id]),
      dynamic(
        [replied, activity: activity, subject_character: subject_character],
          (replied.thread_id == ^thread_id  or replied.id == ^thread_id or replied.reply_to_id == ^thread_id) and activity.verb_id==^verb_id
      )
    }
  end

  def list_replies(thread, current_user, cursor \\ nil, max_depth \\ 3, limit \\ 500)
  def list_replies(%{id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(%{thread_id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(thread_id, current_user, cursor, max_depth, limit) when is_binary(thread_id), do: Pointers.ULID.dump(thread_id) |> do_list_replies(current_user, cursor, max_depth, limit)

  defp do_list_replies({:ok, thread_id}, current_user, cursor, max_depth, limit) do
    # IO.inspect(cursor: cursor)
    %Replied{id: thread_id}
      |> Replied.descendants()
      |> Replied.where_depth(is_smaller_than_or_equal_to: max_depth)
      |> Activities.object_preload_create_activity(current_user)
      |> Activities.as_permitted_for(current_user)
      # |> preload_join(:post)
      # |> preload_join(:post, :post_content)
      # |> preload_join(:activity)
      # |> preload_join(:activity, :subject_profile)
      # |> preload_join(:activity, :subject_character)
      |> Bonfire.Repo.many_paginated(limit: limit, before: Utils.e(cursor, :before, nil), after: Utils.e(cursor, :after, nil)) # return a page of items + pagination metadata
      # |> repo().all # without pagination
      # |> IO.inspect
  end

  def arrange_replies_tree(replies), do: replies |> Replied.arrange()

  # def replies_tree(replies) do
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

end
