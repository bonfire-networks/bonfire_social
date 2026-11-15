if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.ReplyToBoundaryTest do
    @moduledoc """
    `replied.reply_to` is loaded through the pointer dataloader, which must apply the viewer's boundaries: someone who can read a reply but not the post it answers gets no parent.
    """
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @query """
    query($id: ID!) {
      post(filter: {id: $id}) {
        id
        activity { replied { reply_to { id } } }
      }
    }
    """

    defp reply_to_id(viewer, reply) do
      {:ok, result} =
        Absinthe.run(@query, Schema,
          variables: %{"id" => reply.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      # the reply itself is readable, whatever its parent is
      assert get_in(result, [:data, "post", "id"]) == reply.id
      get_in(result, [:data, "post", "activity", "replied", "reply_to", "id"])
    end

    defp publish!(user, body, boundary, reply_to_id \\ nil) do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: body}, reply_to_id: reply_to_id},
          boundary: boundary
        )

      post
    end

    setup do
      author = fake_user!(fake_account!())
      viewer = fake_user!(fake_account!())
      {:ok, author: author, viewer: viewer}
    end

    test "control: a viewer who can read the parent gets it", %{author: author, viewer: viewer} do
      parent = publish!(author, "A public parent", "public")
      reply = publish!(author, "A public reply", "public", parent.id)

      assert reply_to_id(viewer, reply) == parent.id
    end

    test "a viewer who can't read the parent doesn't get it", %{author: author, viewer: viewer} do
      parent = publish!(author, "A private parent", "mentions")
      reply = publish!(author, "A public reply to a private parent", "public", parent.id)

      assert {:error, _} = Bonfire.Posts.read(parent.id, current_user: viewer)
      assert {:ok, _} = Bonfire.Posts.read(reply.id, current_user: viewer)

      assert reply_to_id(viewer, reply) == nil
    end
  end
end
