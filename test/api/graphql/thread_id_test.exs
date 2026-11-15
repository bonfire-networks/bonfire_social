if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.ThreadIdTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @feed """
    query {
      feed_activities(first: 20, filter: {feed_name: "local", preload: ["with_replied", "with_thread"]}) {
        edges {
          node {
            object_id
            replied {
              thread_id
            }
          }
        }
      }
    }
    """

    setup do
      author = fake_user!(fake_account!())
      viewer = fake_user!(fake_account!())
      {:ok, author: author, viewer: viewer}
    end

    test "does not name the thread root when the viewer cannot read it", %{
      author: author,
      viewer: viewer
    } do
      {:ok, root} = publish(author, "Private root", "mentions")
      {:ok, reply} = publish(author, "Public reply", "public", reply_to_id: root.id)

      assert reply_thread_id(viewer, reply) == nil
    end

    test "names the thread root when the viewer can read it", %{author: author, viewer: viewer} do
      {:ok, root} = publish(author, "Public root", "public")
      {:ok, reply} = publish(author, "Public reply", "public", reply_to_id: root.id)

      assert reply_thread_id(viewer, reply) == root.id
    end

    defp publish(user, body, boundary, attrs \\ []) do
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: Map.merge(%{post_content: %{html_body: body}}, Map.new(attrs)),
        boundary: boundary
      )
    end

    defp reply_thread_id(viewer, reply) do
      {:ok, result} =
        Absinthe.run(@feed, Schema, context: Schema.context(%{current_user: viewer}))

      refute result[:errors]

      node =
        get_in(result, [:data, "feed_activities", "edges"])
        |> Enum.map(& &1["node"])
        |> Enum.find(&(&1["object_id"] == reply.id))

      assert node, "the public reply should be in the viewer's feed"
      get_in(node, ["replied", "thread_id"])
    end
  end
end
