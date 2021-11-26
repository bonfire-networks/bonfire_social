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
    field(:subject, :agent)

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
  end

  object :post_content do
    field(:title, :string)
    field(:summary, :string)
    field(:html_body, :string)
  end


  object :posts_page do
    field(:page_info, non_null(:page_info))
    field(:edges, non_null(list_of(non_null(:post))))
    field(:total_count, non_null(:integer))
  end


  object :social_queries do

    @desc "Get all posts"
    field :posts, list_of(:post) do
      resolve &list_posts/3
    end

  end

  object :social_mutations do

  end


  def list_posts(_parent, args, info) do
    {:ok, Bonfire.Social.Posts.query(args, GraphQL.current_user(info))}
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

end
end