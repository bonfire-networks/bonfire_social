defmodule Bonfire.Social.Posts do

  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities, Objects}
  alias Ecto.Changeset
  # import Bonfire.Boundaries.Queries
  alias Bonfire.Social.Threads
  alias Bonfire.Social.PostContents
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.Integration

  import Bonfire.Common.Utils

  use Bonfire.Repo.Query,
      schema: Post,
      searchable_fields: [:id],
      sortable_fields: [:id]

  # def queries_module, do: Post
  def context_module, do: Post
  def federation_module, do: [{"Create", "Note"}, {"Update", "Note"}, {"Create", "Article"}, {"Update", "Article"}]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, post} <- create(creator, attrs) do
      {:ok, post}
    end
  end

  def publish(%{} = creator, attrs, mentions_are_private? \\ true, replies_are_private? \\ false) do
    with  {:ok, post} <- do_publish(creator, attrs, mentions_are_private?, replies_are_private?) do

      {:ok, post}
    end
  end

  defp do_publish(%{} = creator, attrs, mentions_are_private? \\ true, replies_are_private? \\ false) do
  # TODO: make mentions_are_private? and replies_are_private? defaults configurable

    circles = e(attrs, :circles, [])

    #IO.inspect(attrs)
    repo().transact_with(fn ->
      with  {text, mentions, hashtags} <- Bonfire.Tag.TextContent.Process.process(creator, attrs),
        {:ok, post} <- create(creator, attrs, text),
        {:ok, post} <- Bonfire.Social.Tags.maybe_tag(creator, post, mentions, mentions_are_private?),
        {:ok, activity} <- FeedActivities.publish(creator, :create, post, circles, mentions_are_private?, replies_are_private?) do

          post_with_activity = Activities.activity_under_object(activity)

          cc = if mentions_are_private?, do: circles, else: circles ++ (Bonfire.Tag.Tags.tag_ids(mentions) || []) # TODO: don't re-fetch tags

          cc = if replies_are_private?, do: cc, else: cc ++ [ e(post_with_activity, :replied, :reply_to, %{}) |> Objects.object_creator() |> e(:id, nil) ]

          Bonfire.Me.Users.Boundaries.maybe_make_visible_for(creator, post, cc) # |> IO.inspect(label: "grant")


          maybe_index(activity)

          {:ok, post_with_activity}

      end
    end)
  end

  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do

  #     reply = Map.merge(r, published)
  #     # |> IO.inspect

  #     pubsub_broadcast(e(reply, :thread_id, nil), {{Bonfire.Social.Posts, :new_reply}, reply}) # push to online users

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

  def read(post_id, socket_or_current_user \\ nil, preloads \\ :all) when is_binary(post_id) do

    current_user = current_user(socket_or_current_user)

    with {:ok, post} <- query([id: post_id], current_user, preloads)
      |> Activities.read(socket_or_current_user) do


        {:ok, Activities.activity_under_object(post) }

      end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, current_user \\ nil, cursor_after \\ nil, preloads \\ :all) when is_binary(by_user) or is_list(by_user) do

    # query FeedPublish
    [feed_id: by_user, posts_by: {by_user, &filter/3}]
    |> FeedActivities.feed_paginated(current_user, cursor_after, preloads)
  end

  @doc """
  For internal use only (doesn't check permissions). Use `read` instead.
  """
  def get(id) when is_binary(id) do
    repo().single(get_query(id))
  end


  def query(filters \\ [], current_user \\ nil, preloads \\ :all)

  def query(filters, current_user, preloads) when is_list(filters) or is_tuple(filters) do

    Post
    |> EctoShorts.filter(filters, nil, nil)
    |> join_preload([:post_content])
    # |> IO.inspect(label: "post query")
    # TODO: preloads? + check boundaries
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

  def ap_publish_activity("create", post) do
    {:ok, actor} = ActivityPub.Adapter.get_actor_by_id(e(post, :created, :creator_id, nil))
    #FIXME only publish to public URI if in a public enough cirlce
    to = ["https://www.w3.org/ns/activitystreams#Public"]

    cc = [actor.data["followers"]]

    object = %{
      "type" => "Note",
      "actor" => actor.ap_id,
      "name" => e(post, :post_content, :name, nil),
      "summary" => e(post, :post_content, :summary, nil),
      "content" => e(post, :post_content, :html_body, nil),
      "to" => to,
      "cc" => cc
    }

    object =
      if post.replied.reply_to_id do
        ap_object = ActivityPub.Object.get_by_pointer_id(post.replied.reply_to_id)
        Map.put(object, "inReplyTo", ap_object.data["id"])
      else
        object
      end

    attrs = %{
      actor: actor,
      context: ActivityPub.Utils.generate_context_id(),
      object: object,
      to: to,
      additional: %{
        "cc" => cc
      }
    }

    ActivityPub.create(attrs, post.id)
  end

  @doc """
  record an incoming post
  """
  def ap_receive_activity(creator, activity, object, circles \\ [])

  def ap_receive_activity(creator, activity, %{public: true} = object, []) do
    ap_receive_activity(creator, activity, object, [:guests])
  end

  def ap_receive_activity(creator, %{data: _activity_data} = _activity, %{data: post_data} = _object, circles) do # record an incoming post
    # IO.inspect(activity: activity)
    # IO.inspect(creator: creator)
    # IO.inspect(object: object)

    attrs = %{
      local: false, # FIXME?
      canonical_url: nil, # TODO, in a mixin?
      circles: circles,
      post_content: %{
        name: post_data["name"],
        html_body: post_data["content"]
      },
      created: %{
        date: post_data["published"] # FIXME
      }
    }

    attrs =
      if post_data["inReplyTo"] do
        case ActivityPub.Object.get_by_ap_id(post_data["inReplyTo"]) do
          nil -> attrs
          object -> Map.put(attrs, :reply_to_id, object.pointer_id)
        end
      else
        attrs
      end

    with {:ok, post} <- do_publish(creator, attrs, false) do
      # IO.inspect(remote_post: post)
      {:ok, post}
    end
  end


  def indexing_object_format(feed_activity_or_activity, object \\ nil)
  def indexing_object_format(%{subject_profile: subject_profile, subject_character: subject_character} = activity, %{id: id, post_content: post_content} = post) do

    # IO.inspect(obj)

    %{
      "id" => id,
      "index_type" => "Bonfire.Data.Social.Post",
      # "url" => path(post),
      "post_content" => PostContents.indexing_object_format(post_content),
      "creator" => Bonfire.Me.Integration.indexing_format(subject_profile, subject_profile),
      "tag_names" => Bonfire.Social.Integration.indexing_format_tags(activity)
    } #|> IO.inspect
  end
  def indexing_object_format(%{activity: %{object: object} = activity}, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(%Activity{object: object} = activity, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(a, b) do
    Logger.info("Post not indexing")
    IO.inspect(a)
    IO.inspect(b)
    nil
  end

  def maybe_index(object), do: indexing_object_format(object) |> Bonfire.Social.Integration.maybe_index()


end
