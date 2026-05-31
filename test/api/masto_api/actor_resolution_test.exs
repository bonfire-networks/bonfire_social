# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.MastoApi.ActorResolutionTest do
    @moduledoc """
    Regression for group-actor support in the Mastodon API: an activity's actor can be a
    `Bonfire.Classify.Category` (group/topic), not just a `User`. The masto adapters select
    `... on Category { character { username } profile { name } }` on actor fields, which only
    works because the `:category` GraphQL type now exposes `character`/`profile` (they were
    commented out). Before the fix, those selections raised a schema validation error
    ("Cannot query field \\"character\\" on type \\"Category\\""), so a group-authored activity
    resolved to an untyped actor → nil account → the status/notification was silently dropped.
    """
    use Bonfire.Social.MastoApiCase, async: true

    alias Bonfire.Me.Fake
    alias Bonfire.API.GraphQL.Schema

    @moduletag :masto_api

    @query "query ($id: ID) { category(category_id: $id) { id character { username } profile { name summary } } }"

    test "the :category GraphQL type exposes character + profile (so groups can map to masto accounts)" do
      curator = Fake.fake_user!()
      category = Bonfire.Classify.Simulate.fake_category!(curator, nil, %{name: "Test Group"})

      {:ok, result} =
        Absinthe.run(@query, Schema,
          variables: %{"id" => category.id},
          context: Schema.context(%{current_user: curator})
        )

      # The core regression: selecting character/profile on :category must NOT be a schema
      # validation error (it was, before the fields were re-added to the type).
      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"

      assert get_in(result, [:data, "category", "id"]) == category.id
      # The actor selection the masto adapters use must be resolvable on a Category.
      assert Map.has_key?(get_in(result, [:data, "category"]) || %{}, "character")
      assert Map.has_key?(get_in(result, [:data, "category"]) || %{}, "profile")
    end
  end
end
