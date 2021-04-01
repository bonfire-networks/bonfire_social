defmodule Bonfire.Social.FeedActivities do

  alias Bonfire.Data.Social.{Feed, FeedPublish, Like, Boost}
  alias Bonfire.Data.Identity.{User}
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Activities
  alias Bonfire.Common.Utils

  use Bonfire.Repo.Query,
      schema: FeedPublish,
      searchable_fields: [:id, :feed_id, :object_id],
      sortable_fields: [:id]


  def my_feed(user, cursor_before \\ nil) do

    # feeds the user is following
    feed_ids = Feeds.my_feed_ids(user)
    #IO.inspect(inbox_feed_ids: feed_ids)

    feed(feed_ids, user, cursor_before)
  end

  def feed(%{id: feed_id}, current_user \\ nil, cursor_before \\ nil, preloads \\ :all), do: feed(feed_id, current_user, cursor_before, preloads)

  def feed(feed_id_or_ids, current_user, cursor_before, preloads) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do

    Utils.pubsub_subscribe(feed_id_or_ids) # subscribe to realtime feed updates

    # query FeedPublish
    build_query(feed_id: feed_id_or_ids)
    |> feed_query_paginated(current_user, cursor_before, preloads)
  end

  def feed(_, _, _, _), do: []

  def feed_query_paginated(query, current_user \\ nil, cursor_before \\ nil, preloads \\ :all) do

    query
      # add assocs needed in timelines/feeds
      |> join_preload([:activity])
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect(label: "pre-preloads")
      |> Activities.activity_preloads(current_user, preloads)
      # |> IO.inspect(label: "post-preloads")
      # |> Bonfire.Repo.all() # return all items
      |> Bonfire.Repo.many_paginated(before: cursor_before) # return a page of items (reverse chronological) + pagination metadata
      # |> IO.inspect
  end

  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  """

  def publish(subject, verb, %{replied: %{reply_to_id: reply_to_id}} = object) when is_atom(verb) and is_binary(reply_to_id) do
    # publishing a reply to something
    #IO.inspect(publish_reply: object)
    do_publish(subject, verb, object, [Feeds.instance_feed_id(), Feeds.creator_feed(object)])
  end

  def publish(subject, verb, %{tags: tags} = object) when is_atom(verb) and is_list(tags) do
    # publishing something with @ mentions or other tags
    #IO.inspect(publish_tagged: tags)
    do_publish(subject, verb, object, [Feeds.instance_feed_id(), Feeds.tags_feed(tags)])
  end

  def publish(subject, verb, object) when is_atom(verb) do
    do_publish(subject, verb, object, Feeds.instance_feed_id())
  end

  @doc """
  Records a remote activity and puts in appropriate feeds
  """
  def save_fediverse_incoming_activity(subject, verb, object) when is_atom(verb) do
    do_publish(subject, verb, object, Feeds.fediverse_feed_id())
  end

  @doc """
  Creates a new local activity and publishes to object creator's inbox
  """
  def maybe_notify_creator(subject, verb, object) when is_atom(verb) do

    create_and_put_in_feeds(subject, verb, object, Feeds.creator_feed(object))
    # TODO: notify remote users via AP
  end

  @doc """
  Takes an existing activity and puts it in the object creator's inbox
  """
  def maybe_notify_creator(%Bonfire.Data.Social.Activity{} = activity, object) do
    #IO.inspect(activity)
    #IO.inspect(object)
    maybe_notify(activity, Feeds.creator_feed(object))
    # TODO: notify remote users via AP
  end
  def maybe_notify_creator(%{activity: activity}, object), do: maybe_notify_creator(activity, object)

  @doc """
  Creates a new local activity and publishes to object's inbox (if object is an actor)
  """
  def maybe_notify_object(subject, verb, object) when is_atom(verb) do

    create_and_put_in_feeds(subject, verb, object, Feeds.inbox_feed_id(object))
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity and publishes to creator's inbox
  """
  def maybe_notify_admins(subject, verb, object) when is_atom(verb) do

    create_and_put_in_feeds(subject, verb, object, Feeds.admins_inbox())
    # TODO: notify remote users via AP
  end

  def maybe_notify(%{activity: activity}, feed), do: maybe_notify(activity, feed)
  def maybe_notify(%Bonfire.Data.Social.Activity{} = activity, feed) do
    put_in_feeds(feed, activity)
    # TODO: notify remote users via AP
  end


  defp do_publish(subject, verb, object, feeds \\ nil) when is_list(feeds), do: create_and_put_in_feeds(subject, verb, object, feeds ++ [subject])
  defp do_publish(subject, verb, object, feed_id) when not is_nil(feed_id), do: create_and_put_in_feeds(subject, verb, object, [feed_id, subject])
  defp do_publish(subject, verb, object, _), do: create_and_put_in_feeds(subject, verb, object, subject) # just publish to subject's outbox

  defp create_and_put_in_feeds(subject, verb, object, feed_id) when is_binary(feed_id) or is_list(feed_id) do
    with {:ok, activity} <- Activities.create(subject, verb, object),
    {:ok, published} <- put_in_feeds(feed_id, activity) # publish in specified feed
     do
      {:ok, published}
     else
      publishes when is_list(publishes) -> List.first(publishes)
    end
  end
  defp create_and_put_in_feeds(subject, verb, object, %{feed_id: feed_id}), do: create_and_put_in_feeds(subject, verb, object, feed_id)


  defp put_in_feeds(feeds, activity) when is_list(feeds), do: Enum.map(feeds, fn x -> put_in_feeds(x, activity) end) # TODO: optimise?

  defp put_in_feeds(feed_or_subject, activity) do
    with {:ok, %{id: feed_id} = feed} <- Feeds.feed_for_id(feed_or_subject),
    {:ok, published} <- do_put_in_feeds(feed, activity) do

      published = %{published | activity: activity}

      Utils.pubsub_broadcast(feed.id, {:feed_new_activity, activity}) # push to online users
      # Utils.pubsub_broadcast(feed_id, published) # push to online users

      {:ok, published}
    end
  end

  defp do_put_in_feeds(%{id: feed_id}, %{id: activity_as_object_id}) do
    attrs = %{feed_id: feed_id, object_id: activity_as_object_id}
    repo().put(FeedPublish.changeset(attrs))
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_for_object(%{id: id}), do: delete_for_object(id)
  def delete_for_object(id) when is_binary(id) and id !="", do: build_query(object_id: id) |> repo().delete_all() |> elem(1)
  def delete_for_object(ids) when is_list(ids), do: Enum.each(ids, fn x -> delete_for_object(x) end)
  def delete_for_object(_), do: nil

  @doc "Defines additional query filters"

  #doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:create]

    {
      query
      |> join_preload([:activity, :object_post_content])
      |> join_preload([:activity, :object_created])
      |> join_preload([:activity, :replied]),
      dynamic(
        [activity: activity, object_post_content: post, object_created: created, replied: replied],
        is_nil(replied.reply_to_id) and not is_nil(post.id) and activity.verb_id==^verb_id and created.creator_id == ^user_id
      )
    }
  end

  #doc "List likes created by the user and which are in their outbox, which are not replies"
  # FIXME: we are not putting likes in outbox
  def filter(:boosts_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:boost]

    {
      query
      |> join_preload([:activity, :subject_character]),
      dynamic(
        [activity: activity, subject_character: booster],
        activity.verb_id==^verb_id and booster.id == ^user_id
      )
    }
  end

  #doc "List likes created by the user and which are in their outbox, which are not replies"
  # FIXME: we are not putting likes in outbox
  def filter(:likes_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:like]

    {
      query
      |> join_preload([:activity, :subject_character]),
      dynamic(
        [activity: activity, subject_character: liker],
        activity.verb_id==^verb_id and liker.id == ^user_id
      )
    }
  end

end
