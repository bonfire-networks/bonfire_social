if Code.ensure_loaded?(Bonfire.GraphQL) do
defmodule Bonfire.Social.API.GraphQL do
  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers
  alias Bonfire.GraphQL

  object :post do
    field(:id, :string)
    field(:post_content, :post_content)

  end

  object :posts_page do
    field(:page_info, non_null(:page_info))
    field(:edges, non_null(list_of(non_null(:post))))
    field(:total_count, non_null(:integer))
  end

  object :post_content do
    field(:title, :string)
    field(:summary, :string)
    field(:html_body, :string)
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


end
end
