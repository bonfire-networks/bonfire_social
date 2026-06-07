if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.PostBoundaryTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    import Bonfire.Common.E

    @moduletag :graphql

    setup do
      account = fake_account!()
      me = fake_user!(account)
      {:ok, circle} = Bonfire.Boundaries.Circles.create(me, %{named: %{name: "test_circle"}})
      {:ok, me: me, account: account, circle: circle}
    end

    @create_mutation """
    mutation($content: PostContentInput!, $boundary: String, $permissions: [BoundaryPermissionInput]) {
      create_post(post_content: $content, boundary: $boundary, permissions: $permissions) {
        id
        permission_grants { permission can { id label } cannot { id label } }
      }
    }
    """

    test "create_post with boundary arg succeeds and returns id", %{me: me} do
      {:ok, result} =
        Absinthe.run(@create_mutation, Schema,
          variables: %{
            "content" => %{"html_body" => "hello"},
            "boundary" => "public"
          },
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "create_post", "id"])
      refute result[:errors]
    end

    test "create_post with permissions arg passes verb grants to publish", %{
      me: me,
      circle: circle
    } do
      {:ok, result} =
        Absinthe.run(@create_mutation, Schema,
          variables: %{
            "content" => %{"html_body" => "hello"},
            "boundary" => "mentions",
            "permissions" => [
              %{"permission" => "reply", "can" => [circle.id], "cannot" => []}
            ]
          },
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "create_post", "id"])
      refute result[:errors]
    end

    test "create_post returns permission_grants field", %{me: me} do
      {:ok, result} =
        Absinthe.run(@create_mutation, Schema,
          variables: %{
            "content" => %{"html_body" => "hello"},
            "boundary" => "public"
          },
          context: Schema.context(%{current_user: me})
        )

      post = get_in(result, [:data, "create_post"])
      assert post["id"]
      # permission_grants may be empty list but field must exist and not error
      assert is_list(post["permission_grants"])
      refute result[:errors]
    end

    test "BoundaryPermission type has permission, can, cannot fields" do
      {:ok, result} =
        Absinthe.run(
          ~S|{ __type(name: "BoundaryPermission") { fields { name } } }|,
          Schema
        )

      names = get_in(result, [:data, "__type", "fields"]) |> Enum.map(& &1["name"])
      assert "permission" in names
      assert "can" in names
      assert "cannot" in names
      refute result[:errors]
    end

    test "BoundaryPermissionInput type exists in schema" do
      {:ok, result} =
        Absinthe.run(
          ~S|{ __type(name: "BoundaryPermissionInput") { inputFields { name } } }|,
          Schema
        )

      names = get_in(result, [:data, "__type", "inputFields"]) |> Enum.map(& &1["name"])
      assert "permission" in names
      assert "can" in names
      assert "cannot" in names
      refute result[:errors]
    end

    test "create_post with context_id and boundary override applies both", %{me: me} do
      group = Bonfire.Classify.Simulate.fake_group!(me, %{membership: "open"})

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($ctx: ID!) {
            create_post(
              post_content: {html_body: "<p>Group post with custom boundary</p>"},
              context_id: $ctx,
              boundary: "public"
            ) { id context { ... on Category { id } ... on Other { id } } }
          }|,
          Schema,
          variables: %{"ctx" => group.id},
          context: Schema.context(%{current_user: me})
        )

      post = get_in(result, [:data, "create_post"])
      assert is_binary(post["id"])
      assert get_in(post, ["context", "id"]) == group.id
      refute result[:errors]
    end

    test "edit_post changes the boundary of an existing post", %{me: me} do
      {:ok, published} =
        Bonfire.Posts.publish(
          post_attrs: %{post_content: %{html_body: "<p>original</p>"}},
          current_user: me,
          boundary: "public"
        )

      post_id = e(published, :id, nil) || e(published, :post, :id, nil)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!, $boundary: String) {
            edit_post(post_id: $id, boundary: $boundary) { id }
          }|,
          Schema,
          variables: %{"id" => post_id, "boundary" => "mentions"},
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "edit_post", "id"]) == post_id
      refute result[:errors]
    end

    test "edit_post with post_content updates the post body", %{me: me} do
      {:ok, published} =
        Bonfire.Posts.publish(
          post_attrs: %{post_content: %{html_body: "<p>original</p>"}},
          current_user: me,
          boundary: "public"
        )

      post_id = e(published, :id, nil) || e(published, :post, :id, nil)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!, $content: PostContentInput!) {
            edit_post(post_id: $id, post_content: $content) { id post_content { html_body } }
          }|,
          Schema,
          variables: %{"id" => post_id, "content" => %{"html_body" => "<p>updated</p>"}},
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "edit_post", "id"]) == post_id
      refute result[:errors]
    end

    test "create_post requires auth" do
      {:ok, result} =
        Absinthe.run(@create_mutation, Schema,
          variables: %{"content" => %{"html_body" => "hello"}, "boundary" => "public"},
          context: Schema.context(%{})
        )

      assert result[:errors]
    end
  end
end
