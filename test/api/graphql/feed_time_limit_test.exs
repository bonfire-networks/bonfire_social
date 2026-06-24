if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.FeedTimeLimitTest do
    use Bonfire.Social.DataCase, async: false
    use Repatch.ExUnit

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @feed_query """
    query {
      feed_activities(first: 1) {
        edges { node { id } }
      }
    }
    """

    @explicit_time_limit_query """
    query {
      feed_activities(first: 1, filter: {time_limit: 14}) {
        edges { node { id } }
      }
    }
    """

    setup do
      user = fake_user!(fake_account!())
      {:ok, user: user}
    end

    test "feed_activities defaults to an unbounded API time limit", %{user: user} do
      parent = self()

      Repatch.patch(Bonfire.Social.FeedActivities, :feed, fn feed_name, filters, opts ->
        send(parent, {:feed_call, feed_name, filters, opts})
        []
      end)

      {:ok, result} =
        Absinthe.run(@feed_query, Schema, context: Schema.context(%{current_user: user}))

      refute result[:errors]
      assert get_in(result, [:data, "feed_activities", "edges"]) == []
      assert_receive {:feed_call, _feed_name, filters, opts}
      assert opts[:time_limit] == 0
      refute Map.has_key?(filters, :time_limit)
    end

    test "feed_activities still forwards an explicit client time limit", %{user: user} do
      parent = self()

      Repatch.patch(Bonfire.Social.FeedActivities, :feed, fn feed_name, filters, opts ->
        send(parent, {:feed_call, feed_name, filters, opts})
        []
      end)

      {:ok, result} =
        Absinthe.run(@explicit_time_limit_query, Schema,
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]
      assert get_in(result, [:data, "feed_activities", "edges"]) == []
      assert_receive {:feed_call, _feed_name, filters, opts}
      assert opts[:time_limit] == 0
      assert filters[:time_limit] == 14
    end
  end
end
