if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.GroupActivitiesTest do
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @group_and_home_feeds """
    query($group_id: ID!) {
      group_activities(group_id: $group_id, first: 20) {
        edges {
          node {
            id
            object_id
          }
        }
      }
      feed_activities(first: 20, filter: {feed_name: "my"}) {
        edges {
          node {
            id
            object_id
          }
        }
      }
    }
    """

    setup do
      account = fake_account!()
      me = fake_user!(account)
      group = Bonfire.Classify.Simulate.fake_group!(me, %{membership: "open"})

      {:ok, me: me, group: group}
    end

    test "groupActivities does not fall back to the viewer home feed", %{
      me: me,
      group: group
    } do
      outside_post = publish_post!(me, "Outside group feed")

      {:ok, result} =
        Absinthe.run(@group_and_home_feeds, Schema,
          variables: %{"group_id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]

      home_ids = connection_object_ids(result, "feed_activities")
      group_ids = connection_object_ids(result, "group_activities")

      assert outside_post.id in home_ids
      refute outside_post.id in group_ids
    end

    test "groupActivities returns posts scoped to that group", %{
      me: me,
      group: group
    } do
      outside_post = publish_post!(me, "Outside group feed")

      {:ok, group_post_result} =
        Absinthe.run(
          """
          mutation($ctx: ID!) {
            create_post(post_content: {html_body: "<p>Inside group feed</p>"}, context_id: $ctx) {
              id
            }
          }
          """,
          Schema,
          variables: %{"ctx" => group.id},
          context: Schema.context(%{current_user: me})
        )

      refute group_post_result[:errors]
      group_post_id = get_in(group_post_result, [:data, "create_post", "id"])
      assert is_binary(group_post_id) and group_post_id != ""

      {:ok, result} =
        Absinthe.run(@group_and_home_feeds, Schema,
          variables: %{"group_id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]

      group_ids = connection_object_ids(result, "group_activities")

      assert group_post_id in group_ids
      refute outside_post.id in group_ids
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

    defp connection_object_ids(result, field) do
      result
      |> get_in([:data, field, "edges"])
      |> List.wrap()
      |> Enum.map(&get_in(&1, ["node", "object_id"]))
    end
  end
end
