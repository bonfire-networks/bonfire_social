if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.ActivityCountsTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    import Bonfire.Common.E

    @moduletag :graphql

    setup do
      account = fake_account!()
      me = fake_user!(account)
      other = fake_user!(fake_account!())
      {:ok, me: me, other: other}
    end

    test "status exposes bookmark_count", %{me: me, other: other} do
      {:ok, published} =
        Bonfire.Posts.publish(
          post_attrs: %{post_content: %{html_body: "<p>bookmark me</p>"}},
          current_user: me,
          boundary: "public"
        )

      post_id = e(published, :id, nil) || e(published, :post, :id, nil)
      assert is_binary(post_id)

      post = Bonfire.Common.Needles.get!(post_id, current_user: other, skip_boundary_check: true)
      assert {:ok, _bookmark} = Bonfire.Social.Bookmarks.bookmark(other, post)

      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { status(id: $id) { id bookmark_count } }|,
          Schema,
          variables: %{"id" => post_id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      assert get_in(result, [:data, "status", "id"]) == post_id
      assert get_in(result, [:data, "status", "bookmark_count"]) == 1
    end
  end
end
