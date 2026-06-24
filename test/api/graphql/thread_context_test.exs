if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.ThreadContextTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @thread_context """
    query($id: ID!) {
      thread_context(id: $id) {
        ancestors { id }
        descendants { id }
      }
    }
    """

    setup do
      account = fake_account!()
      me = fake_user!(account)
      {:ok, me: me}
    end

    test "returns ancestors and descendants", %{me: me} do
      {:ok, parent} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "Parent post"}},
          boundary: "public"
        )

      {:ok, target} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "Target post"}, reply_to_id: parent.id},
          boundary: "public"
        )

      {:ok, child} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "Child post"}, reply_to_id: target.id},
          boundary: "public"
        )

      {:ok, result} =
        Absinthe.run(@thread_context, Schema,
          variables: %{"id" => target.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]

      ancestor_ids =
        get_in(result, [:data, "thread_context", "ancestors"]) |> Enum.map(& &1["id"])

      descendant_ids =
        get_in(result, [:data, "thread_context", "descendants"]) |> Enum.map(& &1["id"])

      assert parent.id in ancestor_ids
      assert child.id in descendant_ids
    end

    test "returns an error for a non-existent root status", %{me: me} do
      {:ok, result} =
        Absinthe.run(@thread_context, Schema,
          variables: %{"id" => "01JABCDEF0000000000000000X"},
          context: Schema.context(%{current_user: me})
        )

      assert result[:errors]
      assert get_in(result, [:data, "thread_context"]) == nil
    end

    test "returns empty lists for an isolated post", %{me: me} do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "Standalone post"}},
          boundary: "public"
        )

      {:ok, result} =
        Absinthe.run(@thread_context, Schema,
          variables: %{"id" => post.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      assert get_in(result, [:data, "thread_context", "ancestors"]) == []
      assert get_in(result, [:data, "thread_context", "descendants"]) == []
    end
  end
end
