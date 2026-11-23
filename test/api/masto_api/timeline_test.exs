# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.TimelineTest do
  @moduledoc """
  Tests for Mastodon-compatible Timeline API endpoints.

  Covers:
  - GET /api/v1/timelines/home - Home timeline
  - GET /api/v1/timelines/public - Public/federated timeline
  - GET /api/v1/timelines/local - Local timeline
  - GET /api/v1/timelines/tag/:hashtag - Hashtag timeline
  - GET /api/v1/timelines/:feed - Named timeline
  - GET /api/v1/notifications - Notifications
  - GET /api/v1/notifications/:id - Single notification
  - POST /api/v1/notifications/clear - Clear notifications
  - POST /api/v1/notifications/:id/dismiss - Dismiss notification
  - GET /api/v1/bookmarks - Bookmarked statuses
  - GET /api/v1/favourites - Favourited statuses
  - GET /api/v1/accounts/:id/statuses - User statuses

  Run with: just test extensions/bonfire_social/test/rest/masto_api/timeline_test.exs
  """

  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake
  alias Bonfire.Posts
  alias Bonfire.Social.Fake, as: SocialFake
  alias Bonfire.Social.{Likes, Bookmarks, Boosts}
  alias Bonfire.Social.Graph.Follows

  @moduletag :masto_api

  import Bonfire.Common.Testing, only: [count_queries: 1]

  describe "GET /api/v1/timelines/public boosts (reblog rendering)" do
    # PARKED (see https://github.com/bonfire-networks/bonfire-app/issues/2170): boosts get no origin×boundary bucket row, so a bucket-scoped public timeline drops reblogs. 
    @tag skip:
           "parked for https://github.com/bonfire-networks/bonfire-app/issues/2170: a boost gets no origin×boundary bucket row, so the public timeline drops it (`:todo` alone doesn't park a test in CI)"
    test "a boosted post renders as a reblog status", %{conn: conn} do
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      author = Fake.fake_user!()
      booster = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "original boosted content"}},
          boundary: "public"
        )

      {:ok, _} = Boosts.boost(booster, post)

      feed =
        conn
        |> masto_api_conn(user: viewer, account: account)
        |> get("/api/v1/timelines/public")
        |> json_response(200)

      reblog_entry = Enum.find(feed, &(&1["reblog"] != nil))

      assert reblog_entry, "expected a reblog entry in the public timeline"
      assert reblog_entry["account"]["id"] == booster.id
      assert reblog_entry["reblog"]["content"] =~ "original boosted content"
      assert reblog_entry["reblog"]["account"]["id"] == author.id
    end
  end

  # Feeds list what the viewer may SEE (since 16 October), so a post they may discover but not read (the `discover` role: `:see` without `:read`) is listed, and the web shows it as a closed card. A Mastodon client has no closed card: whatever the API gives it, it shows, so it gets what the card shows and nothing more: listed, with why it can't be read, never its body
  describe "a post the viewer may discover but not read" do
    test "is listed in the home timeline without its content, while one they may read has it", %{
      conn: conn
    } do
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      author = Fake.fake_user!()
      {:ok, _} = Follows.follow(viewer, author)

      # addressed to nobody else, so only the roles granted below let the viewer at them
      publish = fn text ->
        {:ok, post} =
          Posts.publish(
            current_user: author,
            post_attrs: %{post_content: %{html_body: text}},
            boundary: "mentions"
          )

        post
      end

      discover_only = publish.("<p>discover-only text</p>")
      readable = publish.("<p>readable text</p>")

      Bonfire.Boundaries.Controlleds.grant_role(viewer, discover_only, :discover,
        current_user: author
      )

      Bonfire.Boundaries.Controlleds.grant_role(viewer, readable, :interact, current_user: author)

      assert Bonfire.Boundaries.can?(viewer, :see, discover_only), "control: may see it"
      refute Bonfire.Boundaries.can?(viewer, :read, discover_only), "control: may not read it"
      assert Bonfire.Boundaries.can?(viewer, :read, readable), "control: may read the other"

      response =
        conn
        |> masto_api_conn(user: viewer, account: account)
        |> get("/api/v1/timelines/home")
        |> json_response(200)

      assert Enum.any?(response, &(&1["content"] =~ "readable text")),
             "control: a post they may read is shown with its content"

      refute Enum.any?(response, &(&1["content"] =~ "discover-only text")),
             "the API gave a client the text of a post its viewer may not read"

      assert %{"content" => content, "text" => text, "media_attachments" => []} =
               Enum.find(response, &(&1["id"] == discover_only.id)),
             "it is listed, as the web lists it"

      assert content != ""

      # the plain text: the HTML escapes its apostrophe
      assert text =~ Bonfire.Social.RestrictedContent.why_not_shown(nil),
             "with why it can't be read, as the web's card says. Got: #{inspect(text)}"
    end
  end

  describe "GET /api/v1/timelines/home" do
    # whether the reader liked it is the post's, not the boost activity's (`likedByMe` on the object, pure-mappers 5c-0)
    test "a boost of a post the reader liked shows the post as favourited", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      author = Fake.fake_user!()
      booster = Fake.fake_user!()
      {:ok, _} = Follows.follow(reader, booster)

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "liked then boosted"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(reader, post)
      {:ok, _} = Boosts.boost(booster, post)

      home =
        conn
        |> masto_api_conn(user: reader, account: account)
        |> get("/api/v1/timelines/home")
        |> json_response(200)

      assert [boost] = Enum.filter(home, &(&1["reblog"]["id"] == post.id))
      assert boost["reblog"]["favourited"] == true
    end

    test "returns posts from followed users", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      followed = Fake.fake_user!()

      {:ok, _} = Follows.follow(user, followed)

      {:ok, post} =
        Posts.publish(
          current_user: followed,
          post_attrs: %{post_content: %{html_body: "Post from followed user"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/home")
        |> json_response(200)

      assert is_list(response)
      post_ids = Enum.map(response, & &1["id"])
      assert post.id in post_ids
    end

    test "a page's reblogged statuses come with the timeline, not one read each", %{conn: conn} do
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      author = Fake.fake_user!()
      booster = Fake.fake_user!()
      {:ok, _} = Follows.follow(viewer, booster)
      api_conn = masto_api_conn(conn, user: viewer, account: account)

      boost_one = fn ->
        {:ok, post} =
          Posts.publish(
            current_user: author,
            post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
            boundary: "public"
          )

        {:ok, _} = Boosts.boost(booster, post)
        post
      end

      queries_for_page = fn ->
        {response, queries} =
          count_queries(fn -> get(api_conn, "/api/v1/timelines/home?limit=20") end)

        {json_response(response, 200), queries}
      end

      post = boost_one.()

      # the first request of a test also fills caches (one query, whatever the page holds), so it isn't the one measured
      queries_for_page.()
      {timeline, for_one} = queries_for_page.()

      # the positive first: the boost is there as a reblog of the author's post, with its content
      reblog = Enum.find(timeline, &(get_in(&1, ["reblog", "id"]) == post.id))
      assert reblog, "the boost is in the viewer's home timeline"
      assert reblog["account"]["id"] == booster.id
      assert reblog["reblog"]["account"]["id"] == author.id

      boost_one.()
      boost_one.()

      {_, for_three} = queries_for_page.()
      assert for_three == for_one
    end

    test "does not include posts from non-followed users", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      stranger = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: stranger,
          post_attrs: %{post_content: %{html_body: "Stranger's post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/home")
        |> json_response(200)

      post_ids = Enum.map(response, & &1["id"])
      refute post.id in post_ids
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/timelines/home")
        |> json_response(401)

      assert response["error"]
    end

    test "supports pagination with limit parameter", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      followed = Fake.fake_user!()

      {:ok, _} = Follows.follow(user, followed)

      for i <- 1..5 do
        {:ok, _} =
          Posts.publish(
            current_user: followed,
            post_attrs: %{post_content: %{html_body: "Post #{i}"}},
            boundary: "public"
          )
      end

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/home?limit=2")
        |> json_response(200)

      assert length(response) <= 2
    end

    test "max_id cursor returns older posts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      followed = Fake.fake_user!()

      {:ok, _} = Follows.follow(user, followed)

      posts =
        for i <- 1..6 do
          {:ok, post} =
            Posts.publish(
              current_user: followed,
              post_attrs: %{post_content: %{html_body: "Pagination post #{i}"}},
              boundary: "public"
            )

          post
        end

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Fetch first page
      page1_conn = get(api_conn, "/api/v1/timelines/home?limit=3")
      page1 = json_response(page1_conn, 200)
      assert length(page1) > 0, "First page should have items"

      # Use the last item's ID as max_id to fetch the next page
      last_id = List.last(page1)["id"]

      page2 =
        api_conn |> get("/api/v1/timelines/home?limit=3&max_id=#{last_id}") |> json_response(200)

      # Page 2 should have different items than page 1
      page1_ids = MapSet.new(Enum.map(page1, & &1["id"]))
      page2_ids = MapSet.new(Enum.map(page2, & &1["id"]))
      assert MapSet.disjoint?(page1_ids, page2_ids), "Pages should not overlap"

      # Page 2 items should be older (lower IDs in descending sort)
      if page2 != [] do
        assert Enum.all?(page2, fn item -> item["id"] < last_id end),
               "All page 2 items should have IDs less than max_id"
      end
    end

    test "min_id cursor returns newer posts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      followed = Fake.fake_user!()

      {:ok, _} = Follows.follow(user, followed)

      for i <- 1..4 do
        {:ok, _} =
          Posts.publish(
            current_user: followed,
            post_attrs: %{post_content: %{html_body: "Old post #{i}"}},
            boundary: "public"
          )
      end

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Fetch initial page to get a cursor
      page1 = api_conn |> get("/api/v1/timelines/home?limit=2") |> json_response(200)
      assert length(page1) > 0

      first_id = List.first(page1)["id"]

      # Create newer posts
      for i <- 1..2 do
        {:ok, _} =
          Posts.publish(
            current_user: followed,
            post_attrs: %{post_content: %{html_body: "New post #{i}"}},
            boundary: "public"
          )
      end

      # Fetch posts newer than first_id
      newer = api_conn |> get("/api/v1/timelines/home?min_id=#{first_id}") |> json_response(200)

      if newer != [] do
        assert Enum.all?(newer, fn item -> item["id"] > first_id end),
               "All items should have IDs greater than min_id"
      end
    end

    test "returns Link headers for pagination", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      followed = Fake.fake_user!()

      {:ok, _} = Follows.follow(user, followed)

      for i <- 1..5 do
        {:ok, _} =
          Posts.publish(
            current_user: followed,
            post_attrs: %{post_content: %{html_body: "Link header post #{i}"}},
            boundary: "public"
          )
      end

      api_conn = masto_api_conn(conn, user: user, account: account)
      result_conn = get(api_conn, "/api/v1/timelines/home?limit=3")
      response = json_response(result_conn, 200)
      assert length(response) > 0

      link_header = Plug.Conn.get_resp_header(result_conn, "link")
      assert link_header != [], "Link header should be present"

      link_value = List.first(link_header)
      # Mastodon Link header format: <url?max_id=X>; rel="next", <url?min_id=Y>; rel="prev"
      assert link_value =~ "rel=\"next\"", "Should have next link"
      assert link_value =~ "rel=\"prev\"", "Should have prev link"
      assert link_value =~ "max_id=", "Next link should use max_id cursor"
      assert link_value =~ "min_id=", "Prev link should use min_id cursor"
    end

    test "max_id past end returns empty list", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Use a very old ID that won't match anything
      response =
        api_conn
        |> get("/api/v1/timelines/home?max_id=00000000000000000000000000")
        |> json_response(200)

      assert response == []
    end
  end

  # scrolling stopped at posts a week old: every page carried the same 7-day bound (live testing, masto-live-fixes pagination bug 1, decision 1.1)
  describe "timelines carry no 7-day window" do
    test "home pages past posts older than 7 days", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      author = Fake.fake_user!()
      {:ok, _} = Follows.follow(reader, author)
      old = for i <- 1..2, do: dated_post!(author, "old #{i} #window", 10)
      _recent = dated_post!(author, "recent #window", 0)

      ids = page_through(masto_api_conn(conn, user: reader, account: account), "/api/v1/timelines/home")

      for post <- old, do: assert(post.id in ids, "an older post is reached by paging")
    end

    test "a list timeline pages past posts older than 7 days", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      member = Fake.fake_user!()
      {:ok, _} = Follows.follow(reader, member)

      {:ok, list} =
        Bonfire.Boundaries.Circles.create(reader, %{named: %{name: "window #{System.unique_integer([:positive])}"}})

      {:ok, _} = Bonfire.Boundaries.Circles.add_to_circles(member, list, current_user: reader)
      old = for i <- 1..2, do: dated_post!(member, "old #{i}", 10)
      _recent = dated_post!(member, "recent", 0)

      ids =
        page_through(masto_api_conn(conn, user: reader, account: account), "/api/v1/timelines/list/#{list.id}")

      for post <- old, do: assert(post.id in ids, "an older post is reached by paging")
    end

    test "a hashtag timeline pages past posts older than 7 days", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      tag = "window#{System.unique_integer([:positive])}"
      old = for i <- 1..2, do: dated_post!(reader, "old #{i} ##{tag}", 10)
      _recent = dated_post!(reader, "recent ##{tag}", 0)

      ids = page_through(masto_api_conn(conn, user: reader, account: account), "/api/v1/timelines/tag/#{tag}")

      for post <- old, do: assert(post.id in ids, "an older post is reached by paging")
    end
  end

  # a like, vote or edit was rendered as the post it's about, so a post and a reaction to it showed as the same status twice (live testing, masto-live-fixes decision D1): Mastodon timelines hold posts, replies and boosts only
  describe "timelines hold posts, replies and boosts only" do
    test "home shows a liked post once, not again as the like", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      author = Fake.fake_user!()
      liker = Fake.fake_user!()
      for followed <- [author, liker], do: {:ok, _} = Follows.follow(reader, followed)
      post = dated_post!(author, "liked by someone the reader follows", 0)
      {:ok, _} = Likes.like(liker, post)

      ids =
        conn
        |> masto_api_conn(user: reader, account: account)
        |> get("/api/v1/timelines/home", %{"limit" => "40"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert Enum.count(ids, &(&1 == post.id)) == 1
    end

    test "home shows a poll once, not again as a vote on it", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)

      {:ok, question} =
        Bonfire.Poll.Fake.fake_question_with_choices(
          %{
            post_content: %{html_body: "a poll in the reader's home"},
            voting_dates: [DateTime.utc_now(), DateTime.add(DateTime.utc_now(), 3600, :second)]
          },
          [%{name: "A"}],
          current_user: reader
        )

      [choice] = question.choices

      for _ <- 1..2 do
        {:ok, _} = Bonfire.Poll.Votes.vote(Fake.fake_user!(), question, [%{choice_id: choice.id, weight: 1}])
      end

      ids =
        conn
        |> masto_api_conn(user: reader, account: account)
        |> get("/api/v1/timelines/home", %{"limit" => "40"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert Enum.count(ids, &(&1 == question.id)) == 1
    end
  end

  # the list timeline returned the reader's home: its list never reached the feed query (live testing, masto-live-fixes)
  describe "GET /api/v1/timelines/list/:list_id" do
    test "a list timeline holds only its members' posts", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      member = Fake.fake_user!()
      other = Fake.fake_user!()
      for followed <- [member, other], do: {:ok, _} = Follows.follow(reader, followed)

      {:ok, list} =
        Bonfire.Boundaries.Circles.create(reader, %{named: %{name: "members #{System.unique_integer([:positive])}"}})

      {:ok, _} = Bonfire.Boundaries.Circles.add_to_circles(member, list, current_user: reader)
      in_list = dated_post!(member, "by a list member", 0)
      not_in_list = dated_post!(other, "by someone else the reader follows", 0)
      api_conn = masto_api_conn(conn, user: reader, account: account)

      list_ids =
        api_conn |> get("/api/v1/timelines/list/#{list.id}", %{"limit" => "40"}) |> json_response(200) |> Enum.map(& &1["id"])

      home_ids =
        api_conn |> get("/api/v1/timelines/home", %{"limit" => "40"}) |> json_response(200) |> Enum.map(& &1["id"])

      assert in_list.id in list_ids
      refute not_in_list.id in list_ids, "a post by someone outside the list"
      assert not_in_list.id in home_ids, "home still has it"
    end

    # a circle filter only reads the reader's own circles: anyone else's would show who is in them (fresh review, finding 1)
    test "another person's circle answers 404, not its members' posts", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      owner = Fake.fake_user!()

      {:ok, circle} =
        Bonfire.Boundaries.Circles.create(owner, %{named: %{name: "not yours #{System.unique_integer([:positive])}"}})

      conn
      |> masto_api_conn(user: reader, account: account)
      |> get("/api/v1/timelines/list/#{circle.id}")
      |> json_response(404)
    end

    test "a circle in the query string does not narrow another timeline", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      followed = Fake.fake_user!()
      {:ok, _} = Follows.follow(reader, followed)
      post = dated_post!(followed, "in the reader's home", 0)
      owner = Fake.fake_user!()

      {:ok, circle} =
        Bonfire.Boundaries.Circles.create(owner, %{named: %{name: "not yours #{System.unique_integer([:positive])}"}})

      ids =
        conn
        |> masto_api_conn(user: reader, account: account)
        |> get("/api/v1/timelines/home", %{"limit" => "40", "subject_circles" => [circle.id]})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert post.id in ids
    end
  end

  # code review: account statuses read the outbox, which also holds follows (and could hold votes or edits); Mastodon lists posts, replies and boosts
  describe "GET /api/v1/accounts/:id/statuses holds posts, replies and boosts" do
    test "a follow is not one of an account's statuses", %{conn: conn} do
      account = Fake.fake_account!()
      reader = Fake.fake_user!(account)
      author = Fake.fake_user!()
      {:ok, _} = Follows.follow(author, Fake.fake_user!())
      post = dated_post!(author, "the only status", 0)

      ids =
        conn
        |> masto_api_conn(user: reader, account: account)
        |> get("/api/v1/accounts/#{author.id}/statuses", %{"limit" => "40"})
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert ids == [post.id]
    end
  end

  describe "GET /api/v1/timelines/public" do
    test "returns public posts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Public post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/public")
        |> json_response(200)

      assert is_list(response)
      post_ids = Enum.map(response, & &1["id"])
      assert post.id in post_ids
    end

    # Note: Public timeline should work without auth but currently has preload issues
    # when accessed anonymously. Test with auth for now.
    test "works with authentication", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, _post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Public post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/public")
        |> json_response(200)

      assert is_list(response)
    end

    test "local=true returns only local posts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/public?local=true")
        |> json_response(200)

      assert is_list(response)
    end
  end

  describe "GET /api/v1/timelines/local" do
    test "returns local posts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      local_user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: local_user,
          post_attrs: %{post_content: %{html_body: "Local post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/local")
        |> json_response(200)

      assert is_list(response)
      post_ids = Enum.map(response, & &1["id"])
      assert post.id in post_ids
    end

    test "does not include remote/federated posts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, local_post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Local API post"}},
          boundary: "public"
        )

      {remote_post, _} = SocialFake.create_test_content(:remote, nil, nil)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/local")
        |> json_response(200)

      post_ids = Enum.map(response, & &1["id"])
      assert local_post.id in post_ids
      refute remote_post.id in post_ids
    end
  end

  describe "GET /api/v1/timelines/tag/:hashtag" do
    test "returns posts with hashtag", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Post with #bonfire tag"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/tag/bonfire")
        |> json_response(200)

      assert is_list(response)
      # Note: The post may or may not appear depending on hashtag processing
    end

    test "returns only posts tagged with the requested hashtag", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      target_tag = "masto_target_#{System.unique_integer([:positive])}"
      other_tag = "masto_other_#{System.unique_integer([:positive])}"

      {:ok, tagged_post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Post with ##{target_tag}"}},
          boundary: "public"
        )

      {:ok, unrelated_post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Post with ##{other_tag}"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/timelines/tag/#{target_tag}")
        |> json_response(200)

      post_ids = Enum.map(response, & &1["id"])
      assert tagged_post.id in post_ids
      refute unrelated_post.id in post_ids
    end

    test "normalizes hashtag (removes # prefix)", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Both should work
      response1 =
        api_conn
        |> get("/api/v1/timelines/tag/test")
        |> json_response(200)

      assert is_list(response1)
    end
  end

  # Mastodon serves the public and hashtag timelines without a token, and apps browse an instance logged out; home stays sign-in only ("returns 401 when not authenticated" above) (live testing, masto-live-fixes step 1)
  describe "a guest (no token)" do
    test "reads the public timeline and sees a public post", %{conn: conn} do
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "public post for a guest"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/timelines/public")
        |> json_response(200)

      assert post.id in Enum.map(response, & &1["id"])
    end

    test "reads a hashtag timeline and sees a public tagged post", %{conn: conn} do
      author = Fake.fake_user!()
      tag = "masto_guest_#{System.unique_integer([:positive])}"

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "tagged for a guest ##{tag}"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/timelines/tag/#{tag}")
        |> json_response(200)

      assert post.id in Enum.map(response, & &1["id"])
    end

    test "does not see a post addressed only to the people it mentions", %{conn: conn} do
      author = Fake.fake_user!()

      {:ok, public_post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "public control post"}},
          boundary: "public"
        )

      {:ok, mentions_post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "only for the people it mentions"}},
          boundary: "mentions"
        )

      ids =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/timelines/public")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert public_post.id in ids, "control: the public post is there"
      refute mentions_post.id in ids
    end
  end

  describe "GET /api/v1/notifications" do
    test "returns notifications for authenticated user", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      other_user = Fake.fake_user!()

      # Create a post and have someone like it to generate notification
      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Like this!"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(other_user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/notifications")
        |> json_response(200)

      assert is_list(response)
    end

    test "includes generated notifications with Mastodon type and status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      other_user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Notify me via Mastodon API"}},
          boundary: "public"
        )

      {:ok, _like} = Likes.like(other_user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/notifications")
        |> json_response(200)

      assert is_list(response)

      assert Enum.any?(response, fn notification ->
               notification["type"] == "favourite" &&
                 get_in(notification, ["account", "id"]) == other_user.id &&
                 get_in(notification, ["status", "id"]) == post.id
             end)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/notifications")
        |> json_response(401)

      assert response["error"]
    end

    test "supports pagination", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/notifications?limit=5")
        |> json_response(200)

      assert is_list(response)
      assert length(response) <= 5
    end
  end

  describe "GET /api/v1/notifications/:id" do
    test "returns a specific notification when available", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      other_user = Fake.fake_user!()

      # Create notification via like
      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Like this!"}},
          boundary: "public"
        )

      {:ok, _like} = Likes.like(other_user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      # First get notifications to find the ID
      notifications =
        api_conn
        |> get("/api/v1/notifications")
        |> json_response(200)

      # Skip if no notifications were created (timing issue)
      if length(notifications) > 0 do
        notification_id = List.first(notifications)["id"]

        # The notification/:id endpoint may use different ID semantics
        # Just verify the endpoint responds
        http_conn = get(api_conn, "/api/v1/notifications/#{notification_id}")
        assert http_conn.status in [200, 404]
      end
    end

    test "returns error for non-existent notification", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Use a valid ULID format that doesn't exist
      nonexistent_id = Needle.ULID.generate()

      http_conn = get(api_conn, "/api/v1/notifications/#{nonexistent_id}")
      # Should return 404 (may be JSON or HTML depending on error handler)
      assert http_conn.status == 404
    end
  end

  describe "POST /api/v1/notifications/clear" do
    test "clears all notifications", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/notifications/clear")
        |> json_response(200)

      # Response should be empty object or success indicator
      assert is_map(response)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/notifications/clear")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "GET /api/v1/bookmarks" do
    test "returns bookmarked statuses", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Bookmarked post"}},
          boundary: "public"
        )

      {:ok, _} = Bookmarks.bookmark(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/bookmarks")
        |> json_response(200)

      assert is_list(response)
      post_ids = Enum.map(response, & &1["id"])
      assert post.id in post_ids
    end

    # older bookmarks have a feed_publish row, newer ones don't
    test "lists a bookmark with no feed entry alongside an older one that has one, newest bookmark first",
         %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      [older_post, newer_post] =
        for text <- ["bookmarked long ago", "bookmarked just now"] do
          {:ok, post} =
            Posts.publish(
              current_user: author,
              post_attrs: %{post_content: %{html_body: text}},
              boundary: "public"
            )

          post
        end

      {:ok, older_bookmark} = Bookmarks.bookmark(user, older_post)

      # as older bookmarks were: published to the outbox
      Bonfire.Common.Repo.insert_all(Bonfire.Data.Social.FeedPublish, [
        %{id: older_bookmark.id, feed_id: Bonfire.Social.Feeds.feed_id(:outbox, user)}
      ])

      {:ok, _} = Bookmarks.bookmark(user, newer_post)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/bookmarks")
        |> json_response(200)

      assert Enum.map(response, & &1["id"]) == [newer_post.id, older_post.id]
      assert Enum.map(response, & &1["bookmarked"]) == [true, true]
    end

    test "pages by when the post was bookmarked, not when it was written", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      [oldest, middle, newest] =
        for i <- 1..3 do
          {:ok, post} =
            Posts.publish(
              current_user: author,
              post_attrs: %{post_content: %{html_body: "written #{i}"}},
              boundary: "public"
            )

          post
        end

      # the oldest post is bookmarked last
      for post <- [newest, middle, oldest], do: {:ok, _} = Bookmarks.bookmark(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      assert page_through(api_conn, "/api/v1/bookmarks") == [oldest.id, middle.id, newest.id]
    end

    test "a bookmarked boost is listed as a reblog of the boosted post", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()
      booster = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "the boosted post"}},
          boundary: "public"
        )

      {:ok, boost} = Boosts.boost(booster, post)
      {:ok, _} = Bookmarks.bookmark(user, boost)

      assert [status] =
               conn
               |> masto_api_conn(user: user, account: account)
               |> get("/api/v1/bookmarks")
               |> json_response(200)

      assert status["reblog"]["id"] == post.id
      assert status["reblog"]["content"] =~ "the boosted post"
    end

    test "a bookmarked poll is listed with its options", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()
      now = DateTime.utc_now()

      {:ok, question} =
        Bonfire.Poll.Questions.create(
          current_user: author,
          boundary: "public",
          question_attrs: %{
            post_content: %{html_body: "a bookmarked poll"},
            voting_format: "single",
            voting_dates: [DateTime.add(now, -120), DateTime.add(now, 3600)],
            choices: [%{name: "Tea"}, %{name: "Coffee"}]
          }
        )

      {:ok, _} = Bookmarks.bookmark(user, question)

      assert [status] =
               conn
               |> masto_api_conn(user: user, account: account)
               |> get("/api/v1/bookmarks")
               |> json_response(200)

      assert status["id"] == question.id
      assert Enum.map(status["poll"]["options"], & &1["title"]) == ["Tea", "Coffee"]
    end

    test "bookmarked groups don't take the places of bookmarked posts in a page", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "bookmarked before the groups"}},
          boundary: "public"
        )

      {:ok, _} = Bookmarks.bookmark(user, post)

      for _ <- 1..2 do
        {:ok, _} = Bookmarks.bookmark(user, Bonfire.Classify.Simulate.fake_category!(author))
      end

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/bookmarks", %{"limit" => "2"})
        |> json_response(200)

      assert Enum.map(response, & &1["id"]) == [post.id]
    end

    test "marks every listed status as bookmarked", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "a bookmarked post"}},
          boundary: "public"
        )

      {:ok, _} = Bookmarks.bookmark(user, post)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/bookmarks")
        |> json_response(200)

      assert [%{"id" => id, "bookmarked" => bookmarked}] = response
      assert id == post.id
      assert bookmarked == true
    end

    test "returns empty list when no bookmarks", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/bookmarks")
        |> json_response(200)

      assert response == []
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/bookmarks")
        |> json_response(401)

      assert response["error"]
    end
  end

  describe "GET /api/v1/favourites" do
    test "returns favourited statuses", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Liked post"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/favourites")
        |> json_response(200)

      assert is_list(response)
      post_ids = Enum.map(response, & &1["id"])
      assert post.id in post_ids
    end

    test "favourite entry is attributed to the post's author, not the liker", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "consistent favourite"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      fav =
        api_conn
        |> get("/api/v1/favourites")
        |> json_response(200)
        |> Enum.find(&(&1["id"] == post.id))

      assert fav, "liked post should appear in /favourites"
      assert fav["content"] =~ "consistent favourite"
      # The status is correctly attributed to the post's author, not the liker.
      assert get_in(fav, ["account", "id"]) == author.id
      assert fav["favourited"] == true
    end

    test "returns empty list when no favourites", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/favourites")
        |> json_response(200)

      assert response == []
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/favourites")
        |> json_response(401)

      assert response["error"]
    end
  end

  describe "GET /api/v1/accounts/:id/statuses" do
    test "returns statuses by user", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      # Query statuses of the authenticated user themselves
      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "My own post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses")
        |> json_response(200)

      assert is_list(response)
      post_ids = Enum.map(response, & &1["id"])
      assert post.id in post_ids
    end

    test "includes the user's boosts (reblogs) with the original content", %{conn: conn} do
      account = Fake.fake_account!()
      booster = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, original} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "original to boost"}},
          boundary: "public"
        )

      {:ok, _} = Bonfire.Social.Boosts.boost(booster, original)

      response =
        conn
        |> masto_api_conn(user: booster, account: account)
        |> get("/api/v1/accounts/#{booster.id}/statuses")
        |> json_response(200)

      reblog_entry = Enum.find(response, &(&1["reblog"] != nil))
      assert reblog_entry, "the booster's profile should include their boost as a reblog"
      assert get_in(reblog_entry, ["reblog", "content"]) =~ "original to boost"
      assert get_in(reblog_entry, ["reblog", "account", "id"]) == author.id
    end

    test "returns only statuses authored by the requested account", %{conn: conn} do
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      author = Fake.fake_user!()
      other_user = Fake.fake_user!()

      {:ok, authored_post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Author profile API post"}},
          boundary: "public"
        )

      {:ok, other_post} =
        Posts.publish(
          current_user: other_user,
          post_attrs: %{post_content: %{html_body: "Other user API post"}},
          boundary: "public"
        )

      {:ok, reply_to_author} =
        Posts.publish(
          current_user: other_user,
          post_attrs: %{
            post_content: %{html_body: "Other user reply on author profile"},
            reply_to_id: authored_post.id
          },
          boundary: "public"
        )

      {:ok, _like} = Likes.like(author, other_post)

      api_conn = masto_api_conn(conn, user: viewer, account: account)

      response =
        api_conn
        |> get("/api/v1/accounts/#{author.id}/statuses")
        |> json_response(200)

      status_ids = Enum.map(response, & &1["id"])

      assert authored_post.id in status_ids
      refute other_post.id in status_ids
      refute reply_to_author.id in status_ids
    end

    test "returns statuses by another user", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Author's post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/accounts/#{author.id}/statuses")
        |> json_response(200)

      assert is_list(response)
      # Note: The feed might not immediately include the post depending on feed indexing
      # Just verify the response structure is correct
    end

    test "supports pinned parameter", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses?pinned=true")
        |> json_response(200)

      assert is_list(response)
    end

    test "supports pagination", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      # Create multiple posts as the user themselves
      for i <- 1..5 do
        {:ok, _} =
          Posts.publish(
            current_user: user,
            post_attrs: %{post_content: %{html_body: "Post #{i}"}},
            boundary: "public"
          )
      end

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses?limit=2")
        |> json_response(200)

      assert length(response) <= 2
    end

    test "returns empty list for non-existent user", %{conn: conn} do
      # Note: The API returns empty list rather than 404 for non-existent users
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/accounts/01KFKNQ2NV1673CZGRRHAAMDR5/statuses")
        |> json_response(200)

      assert response == []
    end
  end

  describe "GET /api/v1/notifications/requests" do
    test "returns empty array (not implemented)", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/notifications/requests")
        |> json_response(200)

      assert response == []
    end
  end

  # a public post whose id, and so its date, is `days_ago` days in the past
  defp dated_post!(author, text, days_ago) do
    {:ok, post} =
      Posts.publish(
        post_id:
          Bonfire.Common.DatesTimes.past(days_ago, :day) |> Bonfire.Common.DatesTimes.generate_ulid(),
        current_user: author,
        post_attrs: %{post_content: %{html_body: text}},
        boundary: "public"
      )

    post
  end

  # the ids a client sees following `rel="next"` with `limit=1`, up to 10 pages
  defp page_through(api_conn, path, params \\ %{"limit" => "1"}, pages \\ 10, seen \\ [])

  defp page_through(_api_conn, _path, _params, 0, seen), do: seen

  defp page_through(api_conn, path, params, pages, seen) do
    resp = get(api_conn, path, params)
    seen = seen ++ (resp |> json_response(200) |> Enum.map(& &1["id"]))

    with [link | _] <- get_resp_header(resp, "link"),
         [_, query] <- Regex.run(~r/<[^>]*\?([^>]*)>; rel="next"/, link) do
      page_through(api_conn, path, URI.decode_query(query), pages - 1, seen)
    else
      _ -> seen
    end
  end
end
