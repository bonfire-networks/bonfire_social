if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.FlagMutationTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @flag """
    mutation($id: String!) {
      flag(id: $id) {
        id
      }
    }
    """

    setup do
      author = fake_user!(fake_account!())
      reporter = fake_user!(fake_account!())
      {:ok, author: author, reporter: reporter}
    end

    test "flag returns the created flag activity id", %{author: author, reporter: reporter} do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 post_attrs: %{post_content: %{html_body: "<p>flag me</p>"}},
                 current_user: author,
                 boundary: "public"
               )

      {:ok, result} =
        Absinthe.run(@flag, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: reporter})
        )

      refute result[:errors]
      assert get_in(result, [:data, "flag", "id"]) |> non_empty_string?()
    end

    test "flag returns a GraphQL error instead of success-shaped null for a missing object", %{
      reporter: reporter
    } do
      {:ok, result} =
        Absinthe.run(@flag, Schema,
          variables: %{"id" => "01JABCDEF0000000000000000F"},
          context: Schema.context(%{current_user: reporter})
        )

      assert result[:errors]
      assert get_in(result, [:data, "flag"]) == nil
    end

    defp non_empty_string?(value), do: is_binary(value) and value != ""
  end
end
