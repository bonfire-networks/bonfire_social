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

    setup do
      account = fake_account!()
      me = fake_user!(account)
      {:ok, me: me}
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
