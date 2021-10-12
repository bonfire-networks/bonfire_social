defmodule Bonfire.Social.Threads do

  alias Bonfire.Data.Social.Replied
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Boundaries.Verbs
  import Bonfire.Common.Utils

  use Bonfire.Repo.Query,
    schema: Replied,
    searchable_fields: [:id, :thread_id, :reply_to_id],
    sortable_fields: [:id]


  def maybe_push_thread(%{} = creator, %{} = activity, %{replied: %{thread_id: thread_id, reply_to_id: reply_to_id}} = _reply) when is_binary(thread_id) and is_binary(reply_to_id) do

    with {:ok, published} <- FeedActivities.maybe_feed_publish(creator, activity, thread_id) do
      Logger.warn("put in thread feed for anyone following the thread: #{inspect thread_id}")

      Logger.warn("broadcasting to anyone currently viewing the thread")
      pubsub_broadcast(thread_id, {{Bonfire.Social.Posts, :new_reply}, {thread_id, published}})

    end
  end

  def maybe_push_thread(_, _, _), do: nil


  def maybe_reply(%{reply_to: reply_attrs}) when is_map(reply_attrs), do: maybe_reply(reply_attrs)
  def maybe_reply(%{reply_to: reply_to_id}) when is_binary(reply_to_id), do: maybe_reply(%{reply_to_id: reply_to_id})
  def maybe_reply(%{reply_to_id: reply_to_id} = reply_attrs) when is_binary(reply_to_id) and reply_to_id !="" do
    with {:ok, reply_to_replied} <- get_replied(reply_to_id) do
      # object we are replying to already has replied mixin
      reply_obj(reply_attrs, reply_to_replied, reply_to_id)
     else _ ->
      with {:ok, reply_to_replied} <- create(%{id: reply_to_id, thread_id: Map.get(reply_attrs, :thread_id, reply_to_id)}) do
        # created replied mixin for reply_to object
        reply_obj(reply_attrs, reply_to_replied, reply_to_id)
      else _ ->
        # could not
         Map.drop(reply_attrs, [:reply_to_id])
        |> maybe_reply()
      end
     end
  end
  def maybe_reply(%{} = reply_attrs), do: Map.merge(reply_attrs, maybe_reply(nil))
  def maybe_reply(_), do: %{set: true} # makes sure a Replied entry is inserted even for first posts

  defp reply_obj(reply_attrs, reply_to_replied, reply_to_id) do
    Map.merge(reply_attrs, %{
      reply_to: reply_to_replied,
      thread_id: e(reply_attrs, :thread_id,
                    e(reply_to_replied, :thread_id, reply_to_id))
      })
  end

  def get_replied(id) do
    # Bonfire.Common.Pointers.get(id)
    repo().single(from p in Replied, where: p.id == ^id)
  end

  # def create_for_object(%{id: id}=_thing) do
  #   create(%{id: id})
  # end

  defp create(attrs) do
    repo().put(changeset(attrs))
  end

  def changeset(replied \\ %Replied{}, %{} = attrs) do
    Replied.changeset(replied, attrs)
  end

  def read(object_id, socket_or_current_user) when is_binary(object_id) do

    current_user = current_user(socket_or_current_user)

    with {:ok, object} <- Replied |> EctoShorts.filter(id: object_id)
      |> Activities.read(socket_or_current_user) do

        {:ok, object}
      end
  end


  @doc "List participants in a thread (depending on user's boundaries)"
  def list_participants(thread_id, current_user \\ nil, cursor_after \\ nil, preloads \\ :minimal) when is_binary(thread_id) or is_list(thread_id) do

     FeedActivities.feed_paginated(
      [participants_in: {thread_id, &filter/3}],
      current_user, cursor_after, preloads, Replied, false)
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


  def list_replies(thread, current_user, cursor \\ nil, max_depth \\ 3, limit \\ 500)
  def list_replies(%{thread_id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(%{id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(thread_id, current_user, cursor, max_depth, limit) when is_binary(thread_id), do: do_list_replies(thread_id, current_user, cursor, max_depth, limit)

  defp do_list_replies(thread_id, current_user_or_socket, cursor, max_depth, limit) do

    pubsub_subscribe(thread_id, current_user_or_socket) # subscribe to realtime thread updates

    current_user = current_user(current_user_or_socket)
    # IO.inspect(current_user: current_user)

    %Replied{id: Bonfire.Common.Pointers.id_binary(thread_id)}
      |> Replied.descendants()
      |> Replied.where_depth(is_smaller_than_or_equal_to: max_depth)
      |> Activities.object_preload_create_activity(current_user)
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect(label: "thread query")
      # |> preload_join(:post)
      # |> preload_join(:post, :post_content)
      # |> preload_join(:activity)
      # |> preload_join(:activity, :subject_profile)
      # |> preload_join(:activity, :subject_character)
      |> Bonfire.Repo.many_paginated(limit: limit, before: e(cursor, :before, nil), after: e(cursor, :after, nil)) # return a page of items + pagination metadata
      # |> repo().many # without pagination
      |> IO.inspect(label: "thread query")
  end

  def arrange_replies_tree(replies), do: replies |> Replied.arrange() # uses https://github.com/asiniy/ecto_materialized_path

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
  #               Bonfire.Common.maybe_get(acc[reply_to_id], :direct_replies, []) ++ [reply_with_id]
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
