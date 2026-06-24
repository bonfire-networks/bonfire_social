if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.PostQuoteTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    import Bonfire.Common.E

    @moduletag :graphql

    setup do
      account = fake_account!()
      me = fake_user!(account)
      {:ok, me: me, account: account}
    end

    @create_quote """
    mutation($content: PostContentInput!, $quoteId: ID) {
      create_post(post_content: $content, quote_id: $quoteId, boundary: "public") {
        id
      }
    }
    """

    @read_quote """
    query($id: ID!) {
      status(id: $id) {
        id
        quoted {
          ... on Post {
            id
            post_content { html_body }
          }
        }
      }
    }
    """

    test "create_post with quote_id of your own post auto-approves and tags the quote", %{me: me} do
      {:ok, quoted} =
        Bonfire.Posts.publish(
          post_attrs: %{post_content: %{html_body: "<p>original</p>"}},
          current_user: me,
          boundary: "public"
        )

      quoted_id = e(quoted, :id, nil) || e(quoted, :post, :id, nil)
      assert is_binary(quoted_id)

      {:ok, result} =
        Absinthe.run(@create_quote, Schema,
          variables: %{
            "content" => %{"html_body" => "<p>quoting it</p>"},
            "quoteId" => quoted_id
          },
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      post_id = get_in(result, [:data, "create_post", "id"])
      assert is_binary(post_id)

      # The quote relationship is recorded as a tag on the new post (own post
      # auto-approves, so it's tagged immediately rather than left as a request).
      post = Bonfire.Common.Needles.get!(post_id, current_user: me, skip_boundary_check: true)
      quote_tags = Bonfire.Social.Tags.list_tags_quote(post)

      assert Enum.any?(quote_tags, &(e(&1, :id, nil) == quoted_id)),
             "expected the new post to quote-tag #{quoted_id}, got: #{inspect(Enum.map(quote_tags, &e(&1, :id, nil)))}"
    end

    test "status exposes quoted posts for quote-card rendering", %{me: me} do
      {:ok, quoted} =
        Bonfire.Posts.publish(
          post_attrs: %{post_content: %{html_body: "<p>original quote target</p>"}},
          current_user: me,
          boundary: "public"
        )

      quoted_id = e(quoted, :id, nil) || e(quoted, :post, :id, nil)
      assert is_binary(quoted_id)

      {:ok, create_result} =
        Absinthe.run(@create_quote, Schema,
          variables: %{
            "content" => %{"html_body" => "<p>quoting it</p>"},
            "quoteId" => quoted_id
          },
          context: Schema.context(%{current_user: me})
        )

      refute create_result[:errors]
      quote_post_id = get_in(create_result, [:data, "create_post", "id"])
      assert is_binary(quote_post_id)

      {:ok, result} =
        Absinthe.run(@read_quote, Schema,
          variables: %{"id" => quote_post_id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      quoted_posts = get_in(result, [:data, "status", "quoted"])
      assert is_list(quoted_posts)
      assert Enum.any?(quoted_posts, &(&1["id"] == quoted_id))
    end

    test "create_post without quote_id still works (no quote tag)", %{me: me} do
      {:ok, result} =
        Absinthe.run(@create_quote, Schema,
          variables: %{"content" => %{"html_body" => "<p>plain</p>"}},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      assert get_in(result, [:data, "create_post", "id"])
    end
  end
end
