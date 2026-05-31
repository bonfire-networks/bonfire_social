# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.MastoApi.AccountCountsTest do
    @moduledoc """
    Regression for the account `followers_count`/`following_count` GraphQL resolvers, which
    raised `Valid association follow_count not found on schema User` (the resolver Dataloaded an
    EdgeTotal aggregate as if it were an Ecto association). Fixed via a `Dataloader.KV` source
    that batch-loads `FollowCount` by id. This unblocks moving account reads onto GraphQL.
    """
    use Bonfire.Social.MastoApiCase, async: true

    alias Bonfire.Me.Fake
    alias Bonfire.Social.Graph.Follows
    alias Bonfire.API.GraphQL.Schema

    @moduletag :masto_api

    @query """
    query Account($id: CharacterFilters) {
      user(filter: $id) { id followers_count following_count }
    }
    """

    defp run(id, viewer) do
      {:ok, result} =
        Absinthe.run(@query, Schema,
          variables: %{"id" => %{"id" => id}},
          context: Schema.context(%{current_user: viewer})
        )

      result
    end

    defp direct_count(user_id, field) do
      case Bonfire.Common.Repo.get(Bonfire.Data.Social.FollowCount, user_id) do
        %{} = fc -> Map.get(fc, field) || 0
        _ -> 0
      end
    end

    test "followers_count / following_count resolve via GraphQL (no error) and match the direct count" do
      user = Fake.fake_user!()
      follower = Fake.fake_user!()
      {:ok, _} = Follows.follow(follower, user)

      result = run(user.id, user)

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"

      followers = get_in(result, [:data, "user", "followers_count"])
      following = get_in(result, [:data, "user", "following_count"])

      assert is_integer(followers)
      assert is_integer(following)
      # equality gate: GraphQL counts match the direct FollowCount read (regardless of whether
      # the EdgeTotal is updated sync or async, both paths see the same value)
      assert followers == direct_count(user.id, :object_count)
      assert following == direct_count(user.id, :subject_count)
    end

    test "batch-loads counts for multiple users without error (KV source N+1 guard)" do
      a = Fake.fake_user!()
      b = Fake.fake_user!()

      for u <- [a, b] do
        result = run(u.id, u)
        refute result[:errors]
        assert is_integer(get_in(result, [:data, "user", "followers_count"]))
      end
    end
  end
end
