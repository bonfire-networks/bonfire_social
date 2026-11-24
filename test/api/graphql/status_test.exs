if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.StatusTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @status """
    query($id: ID!) {
      status(id: $id) {
        id
      }
    }
    """

    @my_boost """
    query($id: ID!) {
      status(id: $id) {
        id
        my_boost {
          id
          object_id: objectId
        }
      }
    }
    """

    setup do
      account = fake_account!()
      me = fake_user!(account)
      {:ok, me: me}
    end

    # the viewer's own boost, for the Mastodon reblog answer
    test "my_boost is the viewer's boost of the status, about the boosted post", %{me: me} do
      author = fake_user!(fake_account!())

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "a post to boost"}},
          boundary: "public"
        )

      {:ok, boost} = Bonfire.Social.Boosts.boost(me, post)

      {:ok, result} =
        Absinthe.run(@my_boost, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      assert get_in(result, [:data, "status", "my_boost", "id"]) == boost.id
      assert get_in(result, [:data, "status", "my_boost", "object_id"]) == post.id
    end

    test "my_boost is null when the viewer has not boosted the status, even if others have", %{
      me: me
    } do
      author = fake_user!(fake_account!())
      other = fake_user!(fake_account!())

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "a post someone else boosted"}},
          boundary: "public"
        )

      {:ok, _} = Bonfire.Social.Boosts.boost(other, post)

      {:ok, result} =
        Absinthe.run(@my_boost, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      assert get_in(result, [:data, "status", "id"])
      assert get_in(result, [:data, "status", "my_boost"]) == nil
    end

    test "returns a status for a readable object id", %{me: me} do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "GraphQL status regression"}},
          boundary: "public"
        )

      {:ok, result} =
        Absinthe.run(@status, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      assert get_in(result, [:data, "status", "id"])
    end

    test "returns a GraphQL error rather than a success-shaped null for a missing status", %{
      me: me
    } do
      {:ok, result} =
        Absinthe.run(@status, Schema,
          variables: %{"id" => "01JABCDEF0000000000000000Y"},
          context: Schema.context(%{current_user: me})
        )

      assert result[:errors]
      assert get_in(result, [:data, "status"]) == nil
    end
  end
end
