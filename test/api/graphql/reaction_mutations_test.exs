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

    @unboost """
    mutation($id: String!) {
      unboost(id: $id)
    }
    """

    @delete_post """
    mutation($id: String!) {
      delete_post(id: $id)
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
      }
    }
    """

    @unbookmark """
    mutation($id: String!) {
      unbookmark(id: $id)
    }
    """

    @pin """
    mutation($id: String!) {
      pin(id: $id) {
        id
        pinned_by_me
      }
    }
    """

    @unpin """
    mutation($id: String!) {
      unpin(id: $id)
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

    test "unboost returns true only after the domain action succeeds", %{
      author: author,
      viewer: viewer
    } do
      post = publish_post!(author, "GraphQL unboost target")
      assert {:ok, _boost} = Bonfire.Social.Boosts.boost(viewer, post)

      {:ok, result} =
        Absinthe.run(@unboost, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      assert get_in(result, [:data, "unboost"]) == true
      refute Bonfire.Social.Boosts.boosted?(viewer, post)
    end

    test "delete_post deletes the author's own post", %{author: author} do
      post = publish_post!(author, "GraphQL delete target")

      {:ok, result} =
        Absinthe.run(@delete_post, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: author})
        )

      refute result[:errors]
      assert get_in(result, [:data, "delete_post"]) == true
      assert {:error, _} = Bonfire.Posts.read(post.id, skip_boundary_check: true)
    end

    test "delete_post refuses someone else's post, which stays", %{author: author, viewer: viewer} do
      post = publish_post!(author, "GraphQL delete, not yours")

      {:ok, result} =
        Absinthe.run(@delete_post, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      assert result[:errors]
      assert {:ok, _} = Bonfire.Posts.read(post.id, skip_boundary_check: true)
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

    test "pin returns the acted-on status with updated viewer state", %{author: author} do
      post = publish_post!(author, "GraphQL pin target")

      {:ok, result} =
        Absinthe.run(@pin, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: author})
        )

      refute result[:errors]
      assert get_in(result, [:data, "pin", "id"]) == post.id
      assert get_in(result, [:data, "pin", "pinned_by_me"]) == true
      assert Bonfire.Social.Pins.pinned?(author, post)
    end

    # who may pin is `Pins.pin`'s call; only the Mastodon API is author-only
    test "pin accepts someone else's public post", %{author: author, viewer: viewer} do
      post = publish_post!(author, "GraphQL pin, someone else's")

      {:ok, result} =
        Absinthe.run(@pin, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      # `pinned_by_me` is Mastodon's `pinned`: only for pins of the viewer's own posts
      assert get_in(result, [:data, "pin", "pinned_by_me"]) == false
      assert Bonfire.Social.Pins.pinned?(viewer, post)
    end

    test "unpin returns true only after the domain action succeeds", %{author: author} do
      post = publish_post!(author, "GraphQL unpin target")
      assert {:ok, _pin} = Bonfire.Social.Pins.pin(author, post)

      {:ok, result} =
        Absinthe.run(@unpin, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: author})
        )

      refute result[:errors]
      assert get_in(result, [:data, "unpin"]) == true
      refute Bonfire.Social.Pins.pinned?(author, post)
    end

    test "unpin of a post never pinned returns true", %{author: author} do
      post = publish_post!(author, "GraphQL unpin, never pinned")

      {:ok, result} =
        Absinthe.run(@unpin, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: author})
        )

      refute result[:errors]
      assert get_in(result, [:data, "unpin"]) == true
    end

    test "pin without a user returns an error and pins nothing", %{author: author} do
      post = publish_post!(author, "GraphQL pin, logged out")

      {:ok, result} =
        Absinthe.run(@pin, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{})
        )

      assert result[:errors]
      assert get_in(result, [:data, "pin"]) == nil
      refute Bonfire.Social.Pins.pinned?(author, post)
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
