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

    # The account mapper becomes pure (team-docs/plans/masto-pure-mappers.md, unit 1): the counts
    # Mastodon shows must come from GraphQL, batched, and be the numbers Mastodon JSON shows today.

    test "a pending follow request is not a follower" do
      locked = Fake.fake_user!(Fake.fake_account!(), %{}, request_before_follow: true)
      requester = Fake.fake_user!()
      {:ok, _} = Follows.follow(requester, locked)
      assert Follows.requested?(requester, locked)

      result = run(locked.id, locked)
      refute result[:errors]

      # changed on purpose in unit 7 (decision 12, then "accepted-only, batched"): the accepted
      # follows, as the web profile counts them (`Follows.follow_counts/1`), not the `FollowCount`
      # row, which counts the request too
      assert get_in(result, [:data, "user", "followers_count"]) == 0
      assert {0, 0} == Follows.follow_counts(locked)

      # the requester does not follow yet either
      assert get_in(run(requester.id, requester), [:data, "user", "following_count"]) == 0
    end

    test "statuses_count counts the user's posts" do
      user = Fake.fake_user!()

      for text <- ["one", "two"] do
        {:ok, _} =
          Bonfire.Posts.publish(
            current_user: user,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "public"
          )
      end

      {:ok, result} =
        Absinthe.run(
          "query ($id: CharacterFilters) { user(filter: $id) { statuses_count } }",
          Schema,
          variables: %{"id" => %{"id" => user.id}},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]
      assert get_in(result, [:data, "user", "statuses_count"]) == 2
    end

    # it was the account's creation date (live testing, masto-live-fixes step 4)
    test "last_post_at is the date of the user's newest post" do
      user = Fake.fake_user!()

      for days_ago <- [10, 3] do
        {:ok, _} =
          Bonfire.Posts.publish(
            # the id dates the post, as `fake_post!/4` passes it
            post_id:
              Bonfire.Common.DatesTimes.past(days_ago, :day)
              |> Bonfire.Common.DatesTimes.generate_ulid(),
            current_user: user,
            post_attrs: %{post_content: %{html_body: "#{days_ago} days ago"}},
            boundary: "public"
          )
      end

      expected =
        Bonfire.Common.DatesTimes.past(3, :day) |> DateTime.to_date() |> Date.to_iso8601()

      # a datetime (decision 14); the Mastodon mapper keeps its date
      assert String.slice(last_post_at(user, user), 0, 10) == expected
    end

    test "last_post_at is null for a user with no posts" do
      user = Fake.fake_user!()

      assert last_post_at(user, user) == nil
    end

    test "a group has last_post_at too, null without posts (decision 9)" do
      user = Fake.fake_user!()
      group = Bonfire.Classify.Simulate.fake_category!(user)

      {:ok, result} =
        Absinthe.run(
          "query ($ids: [ID!]!) { characters(ids: $ids) { ... on Category { id last_post_at } } }",
          Schema,
          variables: %{"ids" => [group.id]},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      assert [%{"last_post_at" => nil}] = get_in(result, [:data, "characters"])
    end

    defp last_post_at(user, viewer) do
      {:ok, result} =
        Absinthe.run(
          "query ($id: CharacterFilters) { user(filter: $id) { last_post_at } }",
          Schema,
          variables: %{"id" => %{"id" => user.id}},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      get_in(result, [:data, "user", "last_post_at"])
    end

    test "the counts cost the same number of queries for 2 users and for 6" do
      viewer = Fake.fake_user!()
      two = for _ <- 1..2, do: Fake.fake_user!()
      six = for _ <- 1..6, do: Fake.fake_user!()

      # the queries the three counts add to a document that already reads the users
      extra = fn users ->
        queries(users, "id", viewer)

        {_, without} =
          Bonfire.Common.Testing.count_queries(fn -> queries(users, "id", viewer) end)

        {_, with_counts} =
          Bonfire.Common.Testing.count_queries(fn ->
            queries(
              users,
              "id followers_count following_count statuses_count last_post_at",
              viewer
            )
          end)

        with_counts - without
      end

      assert extra.(six) == extra.(two)
    end

    test "me { follow_requests_count } counts the requests waiting for the reader" do
      account = Fake.fake_account!()
      locked = Fake.fake_user!(account, %{}, request_before_follow: true)

      for _ <- 1..2 do
        {:ok, _} = Follows.follow(Fake.fake_user!(), locked)
      end

      {:ok, result} =
        Absinthe.run("{ me { follow_requests_count } }", Schema,
          context: Schema.context(%{current_user: locked, current_account: account})
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      assert get_in(result, [:data, "me", "follow_requests_count"]) == 2
    end

    test "the counts still resolve when the GraphQL context has no Dataloader" do
      user = Fake.fake_user!()

      {:ok, result} =
        Absinthe.run(
          "query ($id: CharacterFilters) { user(filter: $id) { followers_count following_count statuses_count } }",
          Schema,
          variables: %{"id" => %{"id" => user.id}},
          context: %{current_user: user}
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      assert get_in(result, [:data, "user", "followers_count"]) == 0
      assert get_in(result, [:data, "user", "statuses_count"]) == 0
    end

    test "search_accounts takes a zero or negative limit without an error" do
      user = Fake.fake_user!()

      for limit <- [0, -5] do
        {:ok, result} =
          Absinthe.run(
            "query ($q: String!, $limit: Int) { search_accounts(query: $q, limit: $limit) { id } }",
            Schema,
            variables: %{"q" => user.character.username, "limit" => limit},
            context: Schema.context(%{current_user: user})
          )

        refute result[:errors], "limit #{limit}: #{inspect(result[:errors])}"
      end
    end

    test "characters(ids:) leaves out an id that is not a user or a group" do
      user = Fake.fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "not a character"}},
          boundary: "public"
        )

      {:ok, result} =
        Absinthe.run(
          "query ($ids: [ID!]!) { characters(ids: $ids) { ... on User { id } ... on Category { id } } }",
          Schema,
          variables: %{"ids" => [post.id, user.id]},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      assert Enum.map(get_in(result, [:data, "characters"]), & &1["id"]) == [user.id]
    end

    test "characters(ids:) returns users and groups together, in order" do
      user = Fake.fake_user!()
      group = Bonfire.Classify.Simulate.fake_category!(user)

      {:ok, result} =
        Absinthe.run(
          "query ($ids: [ID!]!) { characters(ids: $ids) { ... on User { id character { username } } ... on Category { id character { username } } } }",
          Schema,
          variables: %{"ids" => [group.id, user.id]},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      assert Enum.map(get_in(result, [:data, "characters"]), & &1["id"]) == [group.id, user.id]

      assert Enum.all?(
               get_in(result, [:data, "characters"]),
               &is_binary(&1["character"]["username"])
             )
    end

    test "a group has the same count fields as a user (decision 9)" do
      user = Fake.fake_user!()
      group = Bonfire.Classify.Simulate.fake_category!(user)
      {:ok, _} = Follows.follow(Fake.fake_user!(), group)

      {:ok, result} =
        Absinthe.run(
          "query ($ids: [ID!]!) { characters(ids: $ids) { ... on Category { id followers_count following_count statuses_count } } }",
          Schema,
          variables: %{"ids" => [group.id]},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"

      assert [%{"followers_count" => followers, "following_count" => 0, "statuses_count" => 0}] =
               get_in(result, [:data, "characters"])

      assert followers == direct_count(group.id, :object_count)
      assert followers >= 1
    end

    test "discoverable reads each user's setting, batched (decisions 4, 5, 8)" do
      viewer = Fake.fake_user!()
      hidden = Fake.fake_user!()
      Bonfire.Me.Users.put_privacy_settings(hidden, undiscoverable: true)
      shown = for _ <- 1..5, do: Fake.fake_user!()

      result = queries([hidden | shown], "id discoverable", viewer)
      assert get_in(result, [:data, "u0", "discoverable"]) == false
      assert get_in(result, [:data, "u1", "discoverable"]) == true

      extra = fn users ->
        queries(users, "id", viewer)

        {_, without} =
          Bonfire.Common.Testing.count_queries(fn -> queries(users, "id", viewer) end)

        {_, with_field} =
          Bonfire.Common.Testing.count_queries(fn ->
            queries(users, "id discoverable", viewer)
          end)

        with_field - without
      end

      assert extra.(shown) == extra.(Enum.take(shown, 2))
    end

    # one document reading every user under an alias, so Dataloader can batch across them
    defp queries(users, selection, viewer) do
      body =
        users
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {user, i} ->
          ~s|u#{i}: user(filter: {id: "#{user.id}"}) { #{selection} }|
        end)

      {:ok, result} =
        Absinthe.run("{ #{body} }", Schema, context: Schema.context(%{current_user: viewer}))

      refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"
      result
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
