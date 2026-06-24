if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.ReactionMutationsTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @like """
    mutation($id: String!) {
      like(id: $id) {
        id
        liked_by_me
        like_count
      }
    }
    """

    @unlike """
    mutation($id: String!) {
      unlike(id: $id)
    }
    """

    @boost """
    mutation($id: String!) {
      boost(id: $id) {
        id
        boosted_by_me
        boost_count
      }
    }
    """

    @bookmark """
    mutation($id: String!) {
      bookmark(id: $id) {
        id
        bookmarked_by_me
        bookmark_count
      }
    }
    """

    @unbookmark """
    mutation($id: String!) {
      unbookmark(id: $id)
    }
    """

    setup do
      author = fake_user!(fake_account!())
      viewer = fake_user!(fake_account!())
      {:ok, author: author, viewer: viewer}
    end

    test "like returns the acted-on status with updated viewer state", %{
      author: author,
      viewer: viewer
    } do
      post = publish_post!(author, "GraphQL like target")

      {:ok, result} =
        Absinthe.run(@like, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      assert get_in(result, [:data, "like", "id"]) == post.id
      assert get_in(result, [:data, "like", "liked_by_me"]) == true
      assert get_in(result, [:data, "like", "like_count"]) == 1
    end

    test "unlike returns true only after the domain action succeeds", %{
      author: author,
      viewer: viewer
    } do
      post = publish_post!(author, "GraphQL unlike target")
      assert {:ok, _like} = Bonfire.Social.Likes.like(viewer, post)

      {:ok, result} =
        Absinthe.run(@unlike, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      assert get_in(result, [:data, "unlike"]) == true
    end

    test "boost returns the acted-on status with updated viewer state", %{
      author: author,
      viewer: viewer
    } do
      post = publish_post!(author, "GraphQL boost target")

      {:ok, result} =
        Absinthe.run(@boost, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      assert get_in(result, [:data, "boost", "id"]) == post.id
      assert get_in(result, [:data, "boost", "boosted_by_me"]) == true
      assert get_in(result, [:data, "boost", "boost_count"]) == 1
    end

    test "bookmark returns the acted-on status with updated viewer state", %{
      author: author,
      viewer: viewer
    } do
      post = publish_post!(author, "GraphQL bookmark target")

      {:ok, result} =
        Absinthe.run(@bookmark, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      assert get_in(result, [:data, "bookmark", "id"]) == post.id
      assert get_in(result, [:data, "bookmark", "bookmarked_by_me"]) == true
      assert get_in(result, [:data, "bookmark", "bookmark_count"]) == 1
    end

    test "unbookmark returns true only after the domain action succeeds", %{
      author: author,
      viewer: viewer
    } do
      post = publish_post!(author, "GraphQL unbookmark target")
      assert {:ok, _bookmark} = Bonfire.Social.Bookmarks.bookmark(viewer, post)

      {:ok, result} =
        Absinthe.run(@unbookmark, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      assert get_in(result, [:data, "unbookmark"]) == true
    end

    test "like returns a GraphQL error instead of a success-shaped object when status cannot resolve",
         %{viewer: viewer} do
      {:ok, result} =
        Absinthe.run(@like, Schema,
          variables: %{"id" => "01JABCDEF0000000000000000Z"},
          context: Schema.context(%{current_user: viewer})
        )

      assert result[:errors]
      assert get_in(result, [:data, "like"]) == nil
    end

    defp publish_post!(user, body) do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 post_attrs: %{post_content: %{html_body: "<p>#{body}</p>"}},
                 current_user: user,
                 boundary: "public"
               )

      post
    end
  end
end
