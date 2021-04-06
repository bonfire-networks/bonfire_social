defmodule Bonfire.Social.Threads do

  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Utils
  alias Ecto.Changeset
  import Bonfire.Boundaries.Queries
  import Bonfire.Common.Hooks

  import Ecto.Query
  import Bonfire.Me.Integration

  def maybe_push_thread(%{} = creator, %{} = activity, %{replied: %{thread_id: thread_id, reply_to_id: reply_to_id}} = reply) when is_binary(thread_id) and is_binary(reply_to_id) do

    with {:ok, published} <- FeedActivities.maybe_notify(creator, activity, thread_id) do #|> IO.inspect # push to user following the thread

      Utils.pubsub_broadcast(thread_id, {:post_new_reply, published}) # push to users viewing the thread
    end
  end

  def maybe_push_thread(_, _, _), do: nil


  def maybe_reply(%{reply_to: reply_attrs}), do: maybe_reply(reply_attrs)
  def maybe_reply(%{reply_to_id: reply_to_id} = reply_attrs) when is_binary(reply_to_id) and reply_to_id !="" do
     with {:ok, r} <- get_replied(reply_to_id) do
      Map.merge(reply_attrs, %{reply_to: r})
     else _ ->
      Map.drop(reply_attrs, :reply_to_id)
      |> maybe_reply()
     end
  end
  def maybe_reply(%{} = reply_attrs), do: Map.merge(reply_attrs, maybe_reply(nil))
  def maybe_reply(_), do: %{set: true} # makes sure a Replied entry is inserted even for first posts


  def get_replied(id) do
    repo().single(from p in Replied, where: p.id == ^id)
  end

  def list_replies(%{id: thread_id}, current_user, cursor \\ nil, max_depth \\ 3, limit \\ 500), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
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
