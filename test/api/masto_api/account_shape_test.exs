# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.MastoApi.AccountShapeTest do
    @moduledoc """
    Characterization of the Mastodon `account` JSON, key by key, on every endpoint that returns one.

    Written before the account mapper became pure (team-docs/plans/masto-pure-mappers.md, unit 0), as
    a record of what each endpoint answered then. An assertion changes only by a decision, named at
    the assertion. Changed on purpose in unit 3a (decision 11, 2026-11-22): `url` and `uri` are the stored canonical
    URI (`/pub/actors/<username>`) on every endpoint, where show, lookup and the follow-requests list
    built `/pub/person/<id>` and followers, following (3a), favourited_by and reblogged_by (3b) sent none.
    Two are expected to change on purpose, each by its own decision: the 0 counts on the author of a
    status or notification (decision 3), and `discoverable` for a user who opted out (decision 8).

    Run with: just test extensions/bonfire_social/test/api/masto_api/account_shape_test.exs
    """

    use Bonfire.Social.MastoApiCase, async: true

    alias Bonfire.Me.Fake
    alias Bonfire.Social.Graph.Follows

    @moduletag :masto_api

    # the keys that are the same for every account today
    @fixed %{
      "locked" => false,
      "bot" => false,
      "group" => false,
      "suspended" => false,
      "limited" => false,
      "moved" => nil,
      "memorial" => nil,
      "fields" => [],
      "emojis" => [],
      "roles" => [],
      "hide_collections" => false
    }

    setup %{conn: conn} do
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)

      # `other` has 2 posts, 1 follower (`fan`) and follows 1 user (`friend`)
      other = Fake.fake_user!()
      fan = Fake.fake_user!()
      friend = Fake.fake_user!()
      {:ok, _} = Follows.follow(fan, other)
      {:ok, _} = Follows.follow(other, friend)
      post = publish(other, "First post")
      _ = publish(other, "Second post")

      {:ok,
       viewer: viewer,
       other: other,
       fan: fan,
       friend: friend,
       post: post,
       api_conn: masto_api_conn(conn, user: viewer, account: account)}
    end

    describe "one account, with its real counts" do
      test "GET /api/v1/accounts/:id", %{api_conn: api_conn, other: other} do
        account = api_conn |> get("/api/v1/accounts/#{other.id}") |> json_response(200)

        assert account ==
                 expected(other, [statuses: 2, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
      end

      # it answered the account's creation date (live testing, masto-live-fixes step 4)
      test "GET /api/v1/accounts/:id answers the date of the newest post as last_status_at", %{
        api_conn: api_conn
      } do
        author = Fake.fake_user!()
        _older = publish_dated(author, "Ten days ago", 10)
        newest = publish_dated(author, "Three days ago", 3)

        account = api_conn |> get("/api/v1/accounts/#{author.id}") |> json_response(200)

        assert account["last_status_at"] == date_of(newest)
        refute account["last_status_at"] == String.slice(account["created_at"], 0, 10)
      end

      test "GET /api/v1/accounts/lookup", %{api_conn: api_conn, other: other} do
        account =
          api_conn
          |> get("/api/v1/accounts/lookup?acct=#{other.character.username}")
          |> json_response(200)

        assert account ==
                 expected(other, [statuses: 2, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
      end

      test "a user who opted out of discovery", %{api_conn: api_conn} do
        hidden = Fake.fake_user!()
        Bonfire.Me.Users.put_privacy_settings(hidden, undiscoverable: true)

        account = api_conn |> get("/api/v1/accounts/#{hidden.id}") |> json_response(200)

        # changed on purpose in unit 6 (decision 8): `true` before, the setting was not read (review finding R1)
        assert account["discoverable"] == false

        assert account ==
                 expected(hidden, [statuses: 0, followers: 0, following: 0],
                   url: :actor,
                   nils: :dropped
                 )
                 |> Map.put("discoverable", false)

        # the same in a list and as the author of a status
        {:ok, post} =
          Bonfire.Posts.publish(
            current_user: hidden,
            post_attrs: %{post_content: %{html_body: "From someone hidden"}},
            boundary: "public"
          )

        status = api_conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
        assert status["account"]["discoverable"] == false
      end

      test "the reader's own source shows their choice", %{conn: conn} do
        account = Fake.fake_account!()
        hidden = Fake.fake_user!(account)
        Bonfire.Me.Users.put_privacy_settings(hidden, undiscoverable: true)

        me =
          masto_api_conn(conn, user: hidden, account: account)
          |> get("/api/v1/accounts/verify_credentials")
          |> json_response(200)

        assert me["discoverable"] == false
        assert me["source"]["discoverable"] == false
      end
    end

    describe "accounts found by a search" do
      test "GET /api/v1/accounts/search carries real counts", %{api_conn: api_conn, other: other} do
        accounts =
          api_conn
          |> get("/api/v1/accounts/search?q=#{other.character.username}")
          |> json_response(200)

        found = Enum.find(accounts, &(&1["id"] == other.id))
        assert found, "the user is found by username"

        assert found ==
                 expected(other, [statuses: 2, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
      end

      test "GET /api/v1/accounts/familiar_followers lists followers the reader follows, with real counts",
           %{api_conn: api_conn, viewer: viewer, other: other, fan: fan} do
        {:ok, _} = Follows.follow(viewer, fan)

        [familiar] =
          api_conn
          |> get("/api/v1/accounts/familiar_followers?id[]=#{other.id}")
          |> json_response(200)

        assert familiar["id"] == other.id

        # changed on purpose (masto-live-fixes step 2): the counts were 0, the list selected none
        assert familiar["accounts"] == [
                 expected(fan, [statuses: 0, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
               ]
      end
    end

    describe "the reader's own account" do
      test "GET /api/v1/accounts/verify_credentials has `source` and the pending follow requests",
           %{conn: conn} do
        account = Fake.fake_account!()
        locked = Fake.fake_user!(account, %{}, request_before_follow: true)
        requester = Fake.fake_user!()
        _ = publish(requester, "A requester's post")
        {:ok, _} = Follows.follow(requester, locked)
        assert Follows.requested?(requester, locked)

        api_conn = masto_api_conn(conn, user: locked, account: account)

        me = api_conn |> get("/api/v1/accounts/verify_credentials") |> json_response(200)

        {source, me} = Map.pop(me, "source")

        # changed on purpose in unit 7: a pending request is not a follower (1 before)
        assert me ==
                 expected(locked, [statuses: 0, followers: 0, following: 0],
                   url: :actor,
                   nils: :dropped
                 )

        assert source == %{
                 "indexable" => indexable?(locked),
                 "discoverable" => true,
                 "note" => locked.profile.summary || "",
                 "follow_requests_count" => 1,
                 "hide_collections" => false,
                 "attribution_domains" => [],
                 "privacy" => "public",
                 "sensitive" => false,
                 "language" => "",
                 "fields" => []
               }

        # changed on purpose (masto-live-fixes step 2): the list of requesters carries real counts (0 before, it selected none)
        [request] = api_conn |> get("/api/v1/follow_requests") |> json_response(200)

        assert request ==
                 expected(requester, [statuses: 1, followers: 0, following: 0],
                   url: :actor,
                   nils: :dropped
                 )
      end
    end

    describe "lists of accounts" do
      test "followers and following carry real counts", %{
        api_conn: api_conn,
        other: other,
        fan: fan,
        friend: friend
      } do
        [follower] =
          api_conn |> get("/api/v1/accounts/#{other.id}/followers") |> json_response(200)

        assert follower ==
                 expected(fan, [statuses: 0, followers: 0, following: 1],
                   url: :actor,
                   nils: :dropped
                 )

        [followed] =
          api_conn |> get("/api/v1/accounts/#{other.id}/following") |> json_response(200)

        assert followed ==
                 expected(friend, [statuses: 0, followers: 1, following: 0],
                   url: :actor,
                   nils: :dropped
                 )
      end

      # changed on purpose (masto-live-fixes step 2): blocks and mutes carry real counts (0 before, they selected none)
      # changed on purpose (masto-live-fixes step 5, decision 6.1): a blocked account is no longer listed under mutes too, so the mute is of another account
      test "blocks and mutes carry real counts", %{api_conn: api_conn, other: other, fan: fan} do
        api_conn |> post("/api/v1/accounts/#{other.id}/block") |> json_response(200)
        [blocked] = api_conn |> get("/api/v1/blocks") |> json_response(200)

        assert blocked ==
                 expected(other, [statuses: 2, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )

        api_conn |> post("/api/v1/accounts/#{fan.id}/mute") |> json_response(200)
        [muted] = api_conn |> get("/api/v1/mutes") |> json_response(200)

        assert muted ==
                 expected(fan, [statuses: 0, followers: 0, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
      end

      # changed on purpose (masto-live-fixes step 2): Ice Cubes showed a liker with "0 seguaci" while their profile showed 1
      test "favourited_by and reblogged_by carry real counts", %{
        api_conn: api_conn,
        fan: fan,
        post: post
      } do
        {:ok, _} = Bonfire.Social.Likes.like(fan, post)
        {:ok, _} = Bonfire.Social.Boosts.boost(fan, post)

        [liker] =
          api_conn |> get("/api/v1/statuses/#{post.id}/favourited_by") |> json_response(200)

        assert liker ==
                 expected(fan, [statuses: 0, followers: 0, following: 1],
                   url: :actor,
                   nils: :kept
                 )

        [booster] =
          api_conn |> get("/api/v1/statuses/#{post.id}/reblogged_by") |> json_response(200)

        assert booster ==
                 expected(fan, [statuses: 0, followers: 0, following: 1],
                   url: :actor,
                   nils: :kept
                 )
      end

      test "the accounts of a list carry real counts", %{api_conn: api_conn, other: other} do
        %{"id" => list_id} =
          api_conn |> post("/api/v1/lists", %{"title" => "with counts"}) |> json_response(200)

        api_conn
        |> post("/api/v1/lists/#{list_id}/accounts", %{"account_ids" => [other.id]})
        |> json_response(200)

        [member] = api_conn |> get("/api/v1/lists/#{list_id}/accounts") |> json_response(200)

        assert member["id"] == other.id

        assert Map.take(member, ~w(statuses_count followers_count following_count)) == %{
                 "statuses_count" => 2,
                 "followers_count" => 1,
                 "following_count" => 1
               }
      end

      # one test for both versions: they share one cached list of suggested profiles, and two async tests clearing it raced (masto-live-fixes step 3)
      test "suggested accounts carry real counts, in v2 and in v1", %{api_conn: api_conn} do
        suggested = Fake.fake_user!()
        _ = publish(suggested, "A suggested user's post")

        # test setup, standing in for an admin choosing a suggested profile
        Bonfire.Boundaries.Circles.add_to_circles(
          suggested,
          Bonfire.Boundaries.Scaffold.Instance.suggested_profiles_circle(),
          skip_boundary_check: true
        )

        # the suggested list is cached for a while, under the key of the captured private function (`Bonfire.Common.Cache.key_for_call/2`)
        Bonfire.Common.Cache.remove("&Bonfire.Boundaries.Circles.do_list_suggested_profiles/0()")

        counts = %{"statuses_count" => 1, "followers_count" => 0, "following_count" => 0}

        suggestion =
          api_conn
          |> get("/api/v2/suggestions")
          |> json_response(200)
          |> Enum.find(&(get_in(&1, ["account", "id"]) == suggested.id))

        assert suggestion, "the user added to the suggested profiles is suggested"
        assert Map.take(suggestion["account"], Map.keys(counts)) == counts

        # Ice Cubes' Explore calls v1, which answered 404 (live testing, masto-live-fixes step 3)
        account =
          api_conn
          |> get("/api/v1/suggestions")
          |> json_response(200)
          |> Enum.find(&(&1["id"] == suggested.id))

        assert account, "v1 suggests the same user"
        refute Map.has_key?(account, "source"), "an Account, not a v2 Suggestion"
        assert Map.take(account, Map.keys(counts)) == counts
      end
    end

    describe "an account inside another entity, read from structs before 3c" do
      test "the reported account of a report", %{api_conn: api_conn, other: other} do
        report =
          api_conn
          |> post("/api/v1/reports", %{"account_id" => other.id, "comment" => "spam"})
          |> json_response(200)

        assert report["target_account"] ==
                 expected(other, [statuses: 0, followers: 0, following: 0],
                   url: :actor,
                   nils: :dropped
                 )
      end

      test "the booster's account on a boost response", %{
        api_conn: api_conn,
        viewer: viewer,
        post: post
      } do
        {:ok, _} = Follows.follow(viewer, Fake.fake_user!())
        boost = api_conn |> post("/api/v1/statuses/#{post.id}/reblog") |> json_response(200)

        # changed on purpose in unit 5 (decision 3): the boost status's account has its counts
        assert boost["account"] ==
                 expected(viewer, [statuses: 0, followers: 0, following: 1],
                   url: :actor,
                   nils: :kept
                 )
      end

      test "the participants and the last status's author of a conversation", %{
        api_conn: api_conn,
        viewer: viewer,
        other: other
      } do
        {:ok, message} =
          Bonfire.Messages.send(other, %{
            to_circles: [viewer.id],
            post_content: %{html_body: "A private hello"}
          })

        conversation =
          api_conn
          |> get("/api/v1/conversations")
          |> json_response(200)
          |> Enum.find(&(&1["last_status"]["id"] == message.id))

        assert conversation, "the conversation is listed"

        # changed on purpose in unit 5 (decision 3): the last status's author has its real counts,
        # the same as the account itself reports (`GET /api/v1/accounts/:id`)
        fetched = api_conn |> get("/api/v1/accounts/#{other.id}") |> json_response(200)
        assert fetched["followers_count"] == 1

        assert Map.take(
                 conversation["last_status"]["account"],
                 ~w(id statuses_count followers_count following_count)
               ) ==
                 Map.take(fetched, ~w(id statuses_count followers_count following_count))

        # the participant is the whole account, built from the fixture
        assert Enum.find(conversation["accounts"], &(&1["id"] == other.id)) ==
                 expected(other, [statuses: 2, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
      end
    end

    describe "code review of units 1-3 (2026-11-22)" do
      test "an unknown account id answers 404", %{api_conn: api_conn} do
        api_conn |> get("/api/v1/accounts/#{Needle.UID.generate()}") |> json_response(404)
      end

      test "an unknown acct answers 404", %{api_conn: api_conn} do
        api_conn |> get("/api/v1/accounts/lookup?acct=nobody_here_at_all") |> json_response(404)
      end
    end

    describe "lists are paged and batched (fresh review, 2026-11-22)" do
      test "followers follow `limit` and the Link header to the next page", %{
        api_conn: api_conn,
        other: other
      } do
        # `other` already has `fan`; two more make three followers
        for _ <- 1..2, do: {:ok, _} = Follows.follow(Fake.fake_user!(), other)
        path = "/api/v1/accounts/#{other.id}/followers"

        first = get(api_conn, path, %{"limit" => "2"})
        assert [_, _] = page_one = json_response(first, 200)
        assert max_id = next_max_id(first), "the first page links to the next"

        second = get(api_conn, path, %{"limit" => "2", "max_id" => max_id})
        assert [last] = json_response(second, 200)
        refute last["id"] in Enum.map(page_one, & &1["id"])
      end

      # followed hashtags came back as accounts with no username, which the mapper drops: a short page, and 46 counted against 45 listed (live testing, masto-live-fixes pagination bug 2)
      test "following leaves out followed hashtags", %{api_conn: api_conn, viewer: viewer} do
        followed = for _ <- 1..2, do: follow!(viewer, Fake.fake_user!())
        follow_hashtag!(viewer)

        ids =
          api_conn
          |> get("/api/v1/accounts/#{viewer.id}/following")
          |> json_response(200)
          |> Enum.map(& &1["id"])

        assert Enum.sort(ids) == followed |> Enum.map(& &1.id) |> Enum.sort()
      end

      test "following pages past a followed hashtag", %{api_conn: api_conn, viewer: viewer} do
        [first, second] = for _ <- 1..2, do: follow!(viewer, Fake.fake_user!())
        follow_hashtag!(viewer)
        [third, fourth] = for _ <- 1..2, do: follow!(viewer, Fake.fake_user!())
        path = "/api/v1/accounts/#{viewer.id}/following"

        page_one = get(api_conn, path, %{"limit" => "3"})

        assert ids(page_one) == [fourth.id, third.id, second.id],
               "a full page, newest follow first"

        assert max_id = next_max_id(page_one), "the first page links to the next"

        page_two = get(api_conn, path, %{"limit" => "3", "max_id" => max_id})
        assert ids(page_two) == [first.id]
      end

      test "the GraphQL following field holds no hashtags", %{viewer: viewer} do
        followed = for _ <- 1..2, do: follow!(viewer, Fake.fake_user!())
        follow_hashtag!(viewer)

        {:ok, result} =
          Absinthe.run(
            "query ($filter: CharacterFilters) { user(filter: $filter) { following(first: 10) { edges { node { id } } } } }",
            Bonfire.API.GraphQL.Schema,
            variables: %{"filter" => %{"id" => viewer.id}},
            context: Bonfire.API.GraphQL.Schema.context(%{current_user: viewer})
          )

        refute result[:errors], "expected no GraphQL errors, got: #{inspect(result[:errors])}"

        ids =
          result
          |> get_in([:data, "user", "following", "edges"])
          |> Enum.map(&get_in(&1, ["node", "id"]))

        assert Enum.sort(ids) == followed |> Enum.map(& &1.id) |> Enum.sort()
      end

      test "follow requests past the first page can be reached", %{conn: conn} do
        account = Fake.fake_account!()
        locked = Fake.fake_user!(account, %{}, request_before_follow: true)
        for _ <- 1..3, do: {:ok, _} = Follows.follow(Fake.fake_user!(), locked)
        api_conn = masto_api_conn(conn, user: locked, account: account)

        first = get(api_conn, "/api/v1/follow_requests", %{"limit" => "2"})
        assert [_, _] = page_one = json_response(first, 200)
        assert max_id = next_max_id(first), "the first page links to the next"

        second = get(api_conn, "/api/v1/follow_requests", %{"limit" => "2", "max_id" => max_id})
        assert [last] = json_response(second, 200)
        refute last["id"] in Enum.map(page_one, & &1["id"])
        refute next_max_id(second), "the last page links to no next page"

        # and back: the second page's `rel="prev"` gives the first page again
        assert min_id = link_cursor(second, "prev", "min_id"), "the second page links back"

        back = get(api_conn, "/api/v1/follow_requests", %{"limit" => "2", "min_id" => min_id})
        assert Enum.map(json_response(back, 200), & &1["id"]) == Enum.map(page_one, & &1["id"])
      end

      test "follow requests with a cursor that is not one of ours answer a page", %{conn: conn} do
        account = Fake.fake_account!()
        locked = Fake.fake_user!(account, %{}, request_before_follow: true)
        {:ok, _} = Follows.follow(Fake.fake_user!(), locked)
        api_conn = masto_api_conn(conn, user: locked, account: account)

        for param <- ["max_id", "min_id", "since_id"] do
          response = get(api_conn, "/api/v1/follow_requests", %{param => Needle.UID.generate()})
          assert is_list(json_response(response, 200)), "#{param} answers a list"
        end
      end

      test "familiar followers of an id that is not one answer no accounts", %{api_conn: api_conn} do
        assert [%{"id" => "abc", "accounts" => []}] ==
                 api_conn
                 |> get("/api/v1/accounts/familiar_followers?id[]=abc")
                 |> json_response(200)
      end

      test "followers cost the same number of queries for 2 followers and for 5", %{conn: conn} do
        queries_for = fn followers ->
          account = Fake.fake_account!()
          viewer = Fake.fake_user!(account)
          target = Fake.fake_user!()
          for _ <- 1..followers, do: {:ok, _} = Follows.follow(Fake.fake_user!(), target)
          api_conn = masto_api_conn(conn, user: viewer, account: account)
          path = "/api/v1/accounts/#{target.id}/followers"

          # once before counting, so caches filled by a first request are not counted
          assert length(api_conn |> get(path) |> json_response(200)) == followers

          {_, queries} =
            Bonfire.Common.Testing.count_queries(fn ->
              api_conn |> get(path) |> json_response(200)
            end)

          queries
        end

        assert queries_for.(5) == queries_for.(2)
      end

      # within one page: the test config pages at 2 (`config/test.exs`, `default_pagination_limit`), and favourited_by takes no `limit`
      test "favourited_by costs the same number of queries for 1 liker and for 2", %{conn: conn} do
        queries_for = fn likers ->
          account = Fake.fake_account!()
          viewer = Fake.fake_user!(account)
          post = publish(Fake.fake_user!(), "liked by several")
          for _ <- 1..likers, do: {:ok, _} = Bonfire.Social.Likes.like(Fake.fake_user!(), post)
          api_conn = masto_api_conn(conn, user: viewer, account: account)
          path = "/api/v1/statuses/#{post.id}/favourited_by"

          # once before counting, so caches filled by a first request are not counted
          assert length(api_conn |> get(path) |> json_response(200)) == likers

          {_, queries} =
            Bonfire.Common.Testing.count_queries(fn ->
              api_conn |> get(path) |> json_response(200)
            end)

          queries
        end

        assert queries_for.(2) == queries_for.(1)
      end
    end

    describe "an account inside another entity" do
      test "in a grouped notification, the other actors carry their real counts", %{
        conn: conn,
        other: other,
        fan: fan,
        friend: friend
      } do
        # `friend` (1 follower) likes first, `fan` (follows 1) last: `fan` is the notification's
        # account, `friend` comes from the group's other actors (`subjects_more`)
        post = publish(other, "Liked twice")
        {:ok, _} = Bonfire.Social.Likes.like(friend, post)
        {:ok, _} = Bonfire.Social.Likes.like(fan, post)

        result =
          masto_api_conn(conn, user: other)
          |> get("/api/v2/notifications?types[]=favourite")
          |> json_response(200)

        accounts = Map.new(result["accounts"], &{&1["id"], &1})

        # changed on purpose in unit 5 (decision 3): the notification's account has its counts too
        assert accounts[fan.id] ==
                 expected(fan, [statuses: 0, followers: 0, following: 1],
                   url: :actor,
                   nils: :kept
                 )

        # as before the refactor: the other actors were mapped with their counts
        assert accounts[friend.id] ==
                 expected(friend, [statuses: 0, followers: 1, following: 0],
                   url: :actor,
                   nils: :kept
                 )
      end

      test "the author of a status carries real counts", %{
        api_conn: api_conn,
        other: other,
        post: post
      } do
        status = api_conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)

        # changed on purpose in unit 5 (decision 3): 0 before, the counts were skipped
        assert status["account"] ==
                 expected(other, [statuses: 2, followers: 1, following: 1],
                   url: :actor,
                   nils: :dropped
                 )
      end

      test "the account of a notification carries real counts", %{
        api_conn: api_conn,
        viewer: viewer,
        fan: fan
      } do
        {:ok, _} = Follows.follow(fan, viewer)

        notifications = api_conn |> get("/api/v1/notifications") |> json_response(200)
        follow = Enum.find(notifications, &(&1["type"] == "follow"))
        assert follow, "the follow notification is there"

        # changed on purpose in unit 5 (decision 3): `fan` follows `other` and the viewer
        assert follow["account"] ==
                 expected(fan, [statuses: 0, followers: 0, following: 2],
                   url: :actor,
                   nils: :kept
                 )
      end
    end

    defp follow!(follower, followed) do
      {:ok, _} = Follows.follow(follower, followed)
      followed
    end

    # a hashtag followed as `Bonfire.Tag`'s own API tests do it
    defp follow_hashtag!(follower) do
      {:ok, hashtag} =
        Bonfire.Tag.get_or_create_hashtag("followed#{System.unique_integer([:positive])}")

      {:ok, _} = Follows.follow(follower, hashtag, skip_boundary_check: true)
      hashtag
    end

    defp ids(resp), do: resp |> json_response(200) |> Enum.map(& &1["id"])

    # the `max_id` of the response's `rel="next"` Link, or nil when it has none
    defp next_max_id(conn), do: link_cursor(conn, "next", "max_id")

    # a query parameter of the response's Link with relation `rel`, or nil
    defp link_cursor(conn, rel, param) do
      with [link] <- Plug.Conn.get_resp_header(conn, "link"),
           [_, query] <- Regex.run(~r/<[^>]*\?([^>]*)>; rel="#{rel}"/, link) do
        URI.decode_query(query)[param]
      else
        _ -> nil
      end
    end

    defp publish(author, text) do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "public"
        )

      post
    end

    # a post whose id, and so its date, is `days_ago` days in the past
    defp publish_dated(author, text, days_ago) do
      {:ok, post} =
        Bonfire.Posts.publish(
          # the id dates the post, as `fake_post!/4` passes it
          post_id:
            Bonfire.Common.DatesTimes.past(days_ago, :day)
            |> Bonfire.Common.DatesTimes.generate_ulid(),
          current_user: author,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "public"
        )

      post
    end

    defp date_of(post),
      do:
        post.id
        |> Bonfire.Common.DatesTimes.date_from_pointer()
        |> DateTime.to_date()
        |> Date.to_iso8601()

    # The whole account, built from the fixture rather than from the mapper under test.
    #
    # `url:` is `:actor` everywhere since decision 11 (`/pub/actors/<username>`, the stored canonical
    # URI that GraphQL returns). One thing still differs from one endpoint to the next, so each test
    # names what it gets: `nils:` `:dropped` when the response leaves out keys whose value is nil,
    # `:kept` when it sends them.
    defp expected(user, counts, quirks) do
      :actor = Keyword.fetch!(quirks, :url)
      url = Bonfire.Common.URIs.base_url() <> "/pub/actors/" <> user.character.username

      avatar = user |> Bonfire.Common.Media.avatar_url() |> Bonfire.Common.URIs.based_url()
      header = user |> Bonfire.Common.Media.banner_url() |> Bonfire.Common.URIs.based_url()

      created_at =
        user.id |> Bonfire.Common.DatesTimes.date_from_pointer() |> DateTime.to_iso8601()

      indexable = indexable?(user)

      account =
        Map.merge(@fixed, %{
          "id" => user.id,
          "username" => user.character.username,
          "acct" => user.character.username,
          "display_name" => user.profile.name,
          "note" => Bonfire.Common.Text.maybe_markdown_to_html(user.profile.summary) || "",
          "url" => url,
          "uri" => url,
          "avatar" => avatar,
          "avatar_static" => avatar,
          "header" => header,
          "header_static" => header,
          "created_at" => created_at,
          # the date of the newest post (masto-live-fixes step 4): today for the posts these tests publish, nil without posts or where the endpoint selects no counts (statuses: 0)
          "last_status_at" =>
            Keyword.get_lazy(counts, :last_status_at, fn ->
              if counts[:statuses] > 0, do: Date.to_iso8601(Date.utc_today())
            end),
          "statuses_count" => counts[:statuses],
          "followers_count" => counts[:followers],
          "following_count" => counts[:following],
          "indexable" => indexable,
          "noindex" => not indexable,
          "discoverable" => true
        })

      case Keyword.fetch!(quirks, :nils) do
        :kept -> account
        :dropped -> Map.reject(account, fn {_key, value} -> is_nil(value) end)
      end
    end

    defp indexable?(user),
      do: Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer, user)
  end
end
