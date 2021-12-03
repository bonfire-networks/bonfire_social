if Code.ensure_loaded?(Bonfire.GraphQL) do
defmodule Bonfire.Social.API.GraphQL do
  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers
  alias Bonfire.GraphQL

  object :post do
    field(:id, :string)
    field(:post_content, :post_content)

  end

  object :verb do
    field :verb, :string
    field :verb_display, :string do
      resolve fn
        %{verb: verb}, _, _ ->
          {:ok, Bonfire.UI.Social.ActivityLive.verb_display(verb)}
      end
    end
  end

  object :activity do
    field(:id, :string)
    field(:object_id, :string)
    field(:subject_id, :string)

    field(:subject, :any_character)

    field(:verb, :verb) do
      resolve fn
        %{verb: %{id: _} = verb}, _, _ ->
          {:ok, verb}
        %{activity: %{verb: %{id: _} = verb}}, _, _ ->
          {:ok, verb}
      end
    end

    # field(:object_id, :string)
    field :object, :any_context do
      resolve &activity_object/3
    # fn
    #     %{object: %{id: _} = object}, _, _ ->
    #       {:ok, object}
    #     %{activity: %{object: %{id: _} = object}}, _, _ ->
    #       {:ok, object}
    #   end
    end

    field(:direct_replies, list_of(:replied)) do
      arg :paginate, :paginate # TODO

      resolve dataloader(Pointers.Pointer) #, args: %{my: :followed})
    end

  end

  object :post_content do
    field(:title, :string)
    field(:summary, :string)
    field(:html_body, :string)
  end

  object :follow do
    field(:follower_profile, :profile)
    field(:follower_character, :character)
    field(:followed_profile, :profile)
    field(:followed_character, :character)
  end

  object :replied do
    field(:activity, :activity)
    field(:post, :post)
    field(:post_content, :post_content)

    field(:thread_id, :string)
    field(:reply_to_id, :string)
    # field(:reply_to, :activity)

    field(:direct_replies, list_of(:replied)) do
      arg :paginate, :paginate # TODO

      resolve dataloader(Pointers.Pointer) #, args: %{my: :followed})
    end
  end

  object :posts_page do
    field(:page_info, non_null(:page_info))
    field(:edges, non_null(list_of(non_null(:post))))
    field(:total_count, non_null(:integer))
  end

  input_object :activity_filters do
    field :activity_id, :string
    field :object_id, :string
  end

  input_object :feed_filters do
    field :feed_name, :string
  end

  input_object :post_filters do
    field :id, :string
  end

  object :social_queries do

    @desc "Get all posts"
    field :posts, list_of(:post) do
      resolve &list_posts/3
    end

    @desc "Get a post"
    field :post, :post do
      arg :filter, :post_filters
      resolve &get_post/3
    end

    @desc "Get an activity"
    field :activity, :activity do
      arg :filter, :activity_filters
      resolve &get_activity/3
    end

    @desc "Get activities in a feed"
    field :feed, list_of(:activity) do
      arg :filter, :feed_filters
      arg :paginate, :paginate # TODO

      resolve &feed/2
    end

  end

  object :social_mutations do

  end


  def list_posts(_parent, args, info) do
    {:ok, Bonfire.Social.Posts.query(args, GraphQL.current_user(info))}
  end

  def get_post(_parent, %{filter: %{id: id}} = _args, info) do
    Bonfire.Social.Posts.read(id, GraphQL.current_user(info))
  end

  def get_activity(_parent, %{filter: %{activity_id: id}} = _args, info) do
    Bonfire.Social.Activities.get(id, GraphQL.current_user(info))
  end

  def get_activity(_parent, %{filter: %{object_id: id}} = _args, info) do
    Bonfire.Social.Activities.read(id, GraphQL.current_user(info))
  end

  def activity_object(%{activity: %{object: _object} = activity}, _, _) do
    activity_object(activity)
  end
  def activity_object(%{object: _object} = activity, _, _) do
    activity_object(activity)
  end

  def activity_object(activity) do
    {:ok, Bonfire.Social.Activities.object_from_activity(activity)}
  end

  defp feed(%{filter: filter}, info) do
    feed(filter, info)
  end

  defp feed(args, info) do
    Bonfire.Social.FeedActivities.feed(args, info)
    |> feed()
  end

  defp feed(%{entries: feed}) when is_list(feed) do
    {:ok,
      feed
      |> Enum.map(& Map.get(&1, :activity))
    }
  end

end
end
