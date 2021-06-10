defmodule Bonfire.Social.Posts do

  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Common.Utils
  alias Ecto.Changeset
  # import Bonfire.Boundaries.Queries
  alias Bonfire.Social.Threads
  alias Bonfire.Social.PostContents
  alias Bonfire.Boundaries.Verbs

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

  def publish(creator, attrs, mentions_are_private? \\ true) do

    circles = Utils.e(attrs, :circles, [])

    #IO.inspect(attrs)
    repo().transact_with(fn ->
      with  {text, mentions, hashtags} <- Bonfire.Tag.TextContent.Process.process(creator, attrs),
        {:ok, post} <- create(creator, attrs, text),
        {:ok, tagged} <- Bonfire.Social.Tags.maybe_tag(creator, post, mentions),
        {:ok, activity} <- FeedActivities.publish(creator, :create, post) do

          # IO.inspect(activity: activity)
          # make visible for and put in feeds of:
          # - creator
          # - any selected circles
          # - mentioned characters & notify them (TODO: should be opt-in)
          mentioned = Bonfire.Tag.Tags.tag_ids(mentions) || []
          cc = if mentions_are_private?, do: circles, else: circles ++ mentioned # TODO: don't re-fetch tags
          Bonfire.Me.Users.Boundaries.maybe_make_visible_for(creator, post, cc)
          FeedActivities.maybe_feed_publish(creator, activity, cc)
          unless mentions_are_private?, do: FeedActivities.maybe_notify(creator, activity, post, mentioned)

          Threads.maybe_push_thread(creator, activity, post)

          maybe_index(activity)

          # {post, activity} = Map.pop!(activity, :object)

          # {:ok, post}
          {:ok, Activities.activity_under_object(activity)}

      end
    end)
  end

  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do

  #     reply = Map.merge(r, published)
  #     # |> IO.inspect

  #     Utils.pubsub_broadcast(Utils.e(reply, :thread_id, nil), {{Bonfire.Social.Posts, :new_reply}, reply}) # push to online users

  #     {:ok, reply}
  #   end
  # end

  defp create(%{id: creator_id}, attrs, text \\ nil) do
    attrs = attrs
      |> Map.put(:post_content, PostContents.prepare_content(attrs, text))
      |> Map.put(:created, %{creator_id: creator_id})
      |> Map.put(:replied, Threads.maybe_reply(attrs))
      # |> IO.inspect(label: "Posts.create attrs")

    repo().put(changeset(:create, attrs))
  end


  def changeset(:create, attrs) do
    Post.changeset(%Post{}, attrs)
    |> Changeset.cast_assoc(:post_content, [:required, with: &PostContents.changeset/2])
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast_assoc(:replied, [:required, with: &Replied.changeset/2])
  end

  def read(post_id, socket_or_current_user \\ nil) when is_binary(post_id) do

    current_user = Utils.current_user(socket_or_current_user)

    with {:ok, post} <- Post |> EctoShorts.filter(id: post_id)
      |> Activities.read(socket_or_current_user) do


        {:ok, Activities.activity_under_object(post) } # ugly, but heh

      end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, current_user \\ nil, cursor_before \\ nil, preloads \\ :all) when is_binary(by_user) or is_list(by_user) do

    # query FeedPublish
    [feed_id: by_user, posts_by: {by_user, &filter/3}]
    |> FeedActivities.feed_paginated(current_user, cursor_before, preloads)
  end

  defp get(id) when is_binary(id) do
    repo().single(get_query(id))
  end

  #doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:create]

    query
      |> join_preload([:activity, :object_post])
      |> join_preload([:activity, :object_created])
      |> join_preload([:activity, :replied])
      |> where(
        [activity: activity, object_post: post, object_created: created, replied: replied],
        is_nil(replied.reply_to_id) and not is_nil(post.id) and activity.verb_id==^verb_id and created.creator_id == ^user_id
      )
  end

  def get_query(id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     left_join: re in assoc(p, :replied),
     left_join: rt in assoc(re, :reply_to),
     where: p.id == ^id,
     preload: [post_content: pc, created: cr, replied: {re, [reply_to: rt]}]
  end

  defp by_user(user_id) do
    repo().many(by_user_query(user_id))
  end

  defp by_user_query(user_id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     where: cr.creator_id == ^user_id,
     preload: [post_content: pc, created: cr]
  end

  def indexing_object_format(feed_activity_or_activity, object \\ nil)
  def indexing_object_format(%{subject_profile: subject_profile, subject_character: subject_character} = activity, %{id: id, post_content: post_content} = post) do

    # IO.inspect(obj)

    %{
      "id" => id,
      "index_type" => "Bonfire.Data.Social.Post",
      # "url" => path(post),
      "post_content" => PostContents.indexing_object_format(post_content),
      "activity" => %{
        "subject_profile" => Bonfire.Me.Profiles.indexing_object_format(subject_profile),
        "subject_character" => Bonfire.Me.Characters.indexing_object_format(subject_character),
      },
      "tag_names" => Bonfire.Social.Integration.indexing_format_tags(activity)
    } #|> IO.inspect
  end
  def indexing_object_format(%{activity: %{object: object} = activity}, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(%Activity{object: object} = activity, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(a, b) do
    Logger.info("Not indexing")
    IO.inspect(a)
    IO.inspect(b)
    nil
  end

  def maybe_index(object), do: indexing_object_format(object) |> Bonfire.Social.Integration.maybe_index()


end
