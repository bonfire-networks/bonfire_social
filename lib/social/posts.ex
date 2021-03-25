defmodule Bonfire.Social.Posts do

  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Utils
  alias Ecto.Changeset
  import Bonfire.Boundaries.Queries

  use Bonfire.Repo.Query,
      schema: Post,
      searchable_fields: [:id],
      sortable_fields: [:id]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, post} <- create(creator, attrs) do
      {:ok, post}
    end
  end

  def publish(creator, attrs) do
    # IO.inspect(attrs)
    with  {:ok, post} <- create(creator, attrs),
          {:ok, maybe_tagged} <- maybe_tag(creator, post),
          {:ok, activity} <- FeedActivities.publish(creator, :create, Map.merge(post, maybe_tagged)) do

            Bonfire.Me.Users.Boundaries.maybe_make_visible_for(creator, post, Utils.e(attrs, :circles, nil))

            # IO.inspect(post)
            maybe_notify_thread(post, activity)

      {:ok, %{post: post, activity: activity}}
    end
  end

  defp maybe_tag(creator, post) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: Bonfire.Tag.Tags.maybe_tag(creator, post), #|> IO.inspect
    else: {:ok, post}
    # {:ok, post}
  end

  defp maybe_notify_thread(%{replied: %{thread_id: thread_id, reply_to_id: reply_to_id}} = reply, activity) when is_binary(thread_id) and is_binary(reply_to_id) do

    FeedActivities.maybe_notify(activity, thread_id) |> IO.inspect # push to user following the thread

    Utils.pubsub_broadcast(thread_id, {:thread_new_reply, reply}) # push to users viewing the thread

  end
  defp maybe_notify_thread(_, _), do: nil

  def reply(creator, attrs) do
    with  {:ok, published} <- publish(creator, attrs),
          {:ok, r} <- get_replied(published.post.id) do

      reply = Map.merge(r, published)
      # |> IO.inspect

      Utils.pubsub_broadcast(Utils.e(reply, :thread_id, nil), {:thread_new_reply, reply}) # push to online users

      {:ok, reply}
    end
  end

  defp create(%{id: creator_id}, attrs) do
    attrs = attrs
      |> Map.put(:post_content, prepare_content(attrs))
      |> Map.put(:created, %{creator_id: creator_id})
      |> Map.put(:replied, maybe_reply(attrs))
      # |> IO.inspect

    repo().put(changeset(:create, attrs))
  end

  def prepare_content(%{post_content: %{} = attrs}), do: prepare_content(attrs)
  def prepare_content(%{name: name, html_body: body} = attrs) when is_nil(body) or body=="" do
    # use title as body if no body entered
    Map.merge(attrs, %{html_body: name, name: ""})
  end
  def prepare_content(attrs), do: attrs

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

  defp changeset(:create, attrs) do
    Post.changeset(%Post{}, attrs)
    |> Changeset.cast_assoc(:post_content, [:required, with: &PostContent.changeset/2])
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast_assoc(:replied, [:required, with: &Replied.changeset/2])
  end

  def read(post_id, current_user \\ nil) when is_binary(post_id) do

    with {:ok, post} <- build_query(id: post_id)
      # |> preload_join(:post_content)
      # |> preload_join(:creator_profile)
      # |> preload_join(:creator_character)
      # |> preload_join(:reply_to)
      # |> preload_join(:reply_to_post_content)
      # |> preload_join(:thread_post_content)
      |> Activities.object_preload_create_activity(current_user, [:default, :with_parents])
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect
      |> repo().single() do

        Utils.pubsub_subscribe(Utils.e(post, :activity, :thread_post_content, :id, nil) || post.id) # subscribe to realtime feed updates

        {:ok, post} #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]]) |> IO.inspect
      end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, current_user \\ nil, cursor_before \\ nil, preloads \\ :all) when is_binary(by_user) or is_list(by_user) do

    # query FeedPublish
    FeedActivities.build_query(feed_id: by_user, posts_by: by_user)
    |> FeedActivities.feed_query_paginated(current_user, cursor_before, preloads)
  end

  def get(id) when is_binary(id) do
    repo().single(get_query(id))
  end

  def get_query(id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     left_join: rt in assoc(p, :reply_to),
     where: p.id == ^id,
     preload: [post_content: pc, created: cr, reply_to: rt]
  end

  def by_user(user_id) do
    repo().all(by_user_query(user_id))
  end

  def by_user_query(user_id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     where: cr.creator_id == ^user_id,
     preload: [post_content: pc, created: cr]
  end

  def get_replied(id) do
    repo().single(from p in Replied, where: p.id == ^id)
  end

  def list_replies(%{id: thread_id}, current_user, cursor \\ nil, max_depth \\ 3, limit \\ 500), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(%{thread_id: thread_id}, current_user, cursor, max_depth, limit), do: list_replies(thread_id, current_user, cursor, max_depth, limit)
  def list_replies(thread_id, current_user, cursor, max_depth, limit) when is_binary(thread_id), do: Pointers.ULID.dump(thread_id) |> do_list_replies(current_user, cursor, max_depth, limit)

  defp do_list_replies({:ok, thread_id}, current_user, cursor, max_depth, limit) do
    IO.inspect(cursor: cursor)
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
  #       # IO.inspect(acc: acc)
  #       # IO.inspect(reply_ok: reply)
  #       # IO.inspect(reply_to_id: reply_to_id)

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
  #       # IO.inspect(reply_skip: reply)

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
