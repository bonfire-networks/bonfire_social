defmodule Bonfire.Social.Bonfire.Social.MediaTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Social.Media
  alias Bonfire.Social.Boosts
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  import Tesla.Mock

  # Helper to setup Tesla mocks for URL metadata
  defp setup_url_mocks do
    mock(fn
      %{method: :get, url: "https://example.com/article1"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Article 1 - Great Content</title></head></html>"
        }

      %{method: :get, url: "https://example.com/article2"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Article 2 - Different Topic</title></head></html>"
        }

      %{method: :get, url: "https://example.com/old"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Old Article</title></head></html>"
        }

      %{method: :get, url: "https://example.com/popular"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Very Popular Article</title></head></html>"
        }

      %{method: :get, url: "https://example.com/" <> _} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Generic Article</title></head></html>"
        }
    end)
  end

  describe "with shared fixture data" do
    setup do
      setup_url_mocks()

      # Create fresh test data for each test in isolated transaction
      user1 = Fake.fake_user!("user1")
      user2 = Fake.fake_user!("user2")
      user3 = Fake.fake_user!("user3")

      # Old post (outside default 7-day window)
      old_post =
        fake_post!(user1, "public", %{
          post_content: %{html_body: "Old link https://example.com/old"},
          id: DatesTimes.past(10, :day) |> DatesTimes.generate_ulid()
        })

      # Same URL shared by two users (article1)
      post1 =
        fake_post!(user1, "public", %{
          post_content: %{html_body: "Check this out https://example.com/article1"}
        })

      post2 =
        fake_post!(user2, "public", %{
          post_content: %{html_body: "Also interesting https://example.com/article1"}
        })

      # Different URL (article2)
      post3 =
        fake_post!(user3, "public", %{
          post_content: %{html_body: "See https://example.com/article2"}
        })

      # Add boosts to posts
      # article1 via post1: 2 boosts
      {:ok, _boost1} = Boosts.boost(user2, post1)
      {:ok, _boost2} = Boosts.boost(user3, post1)

      # article1 via post2: 1 boost
      {:ok, _boost3} = Boosts.boost(user1, post2)

      # article2 via post3: 1 boost
      {:ok, _boost4} = Boosts.boost(user1, post3)

      # Add likes
      {:ok, _like1} = Bonfire.Social.Likes.like(user1, post1)
      {:ok, _like2} = Bonfire.Social.Likes.like(user2, post2)
      {:ok, _like3} = Bonfire.Social.Likes.like(user3, post3)

      # Add replies
      reply1 =
        fake_post!(user2, "public", %{
          post_content: %{html_body: "Reply to article1"},
          reply_to_id: post1.id
        })

      reply2 =
        fake_post!(user3, "public", %{
          post_content: %{html_body: "Reply to article1 again"},
          reply_to_id: post2.id
        })

      reply3 =
        fake_post!(user1, "public", %{
          post_content: %{html_body: "Reply to article2"},
          reply_to_id: post3.id
        })

      Bonfire.Social.Objects.ulid_for_x_days_ago(7)
      |> DatesTimes.to_date_time()
      |> flood("Time limit datetime")

      %{
        users: [user1, user2, user3],
        posts: %{
          post1: post1,
          post2: post2,
          post3: post3,
          old_post: old_post
        },
        results: Bonfire.Social.Media.trending_links()
      }
    end

    test "returns trending links with correct structure", %{results: results} do
      assert is_list(results)
      assert length(results) > 0

      first = List.first(results)
      assert Map.has_key?(first, :path)
      assert Map.has_key?(first, :boost_count)
      # assert Map.has_key?(first, :unique_sharers)
      # assert Map.has_key?(first, :sharers)
      assert is_binary(first.path)
      # assert is_integer(first.boost_count) or is_decimal(first.boost_count)
      # assert is_integer(first.unique_sharers)
      # assert is_list(first.sharers)
    end

    test "groups same URL shared by multiple users", %{results: results} do
      # article1 should be grouped into one entry
      article1_entries = Enum.filter(results, &String.contains?(&1.path, "article1"))
      assert length(article1_entries) == 1
    end

    test "aggregates boost counts correctly across multiple shares of same URL", %{
      results: results
    } do
      assert article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
      # post1 has 2 boosts + post2 has 1 boost = 3 total
      assert article1.boost_count == Decimal.new(3)
    end

    # test "counts unique sharers correctly", %{results: results, users: [user1, user2, user3]} do
    #   assert article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
    #   # user1 and user2 shared article1
    #   assert article1.unique_sharers == 2
    #   assert length(article1.sharers) == 2

    #   sharer_ids = Enum.map(article1.sharers, & &1.id)
    #   assert user1.id in sharer_ids
    #   assert user2.id in sharer_ids
    # end

    # test "sorting respects unique_sharers_weight option" do
    #   user1 = Fake.fake_user!()
    #   user2 = Fake.fake_user!()
    #   user3 = Fake.fake_user!()

    #   # Create a post with many boosts but one sharer
    #   popular_post =
    #     fake_post!(user1, "public", %{
    #       post_content: %{html_body: "Very popular https://example.com/popular"}
    #     })

    #   # Add 10 boosts from same user
    #   Enum.each(1..10, fn _ ->
    #     Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], true)
    #     {:ok, _} = Boosts.boost(user2, popular_post)
    #   end)

    #   # Create posts with less boosts but more unique sharers (using different URL to avoid collision)
    #   post_a =
    #     fake_post!(user1, "public", %{
    #       post_content: %{html_body: "Diverse https://example.com/diverse1"}
    #     })

    #   post_b =
    #     fake_post!(user2, "public", %{
    #       post_content: %{html_body: "Also diverse https://example.com/diverse1"}
    #     })

    #   {:ok, _} = Boosts.boost(user3, post_a)
    #   {:ok, _} = Boosts.boost(user1, post_b)

    #   # With high weight on unique sharers, diverse1 should rank higher
    #   results = Bonfire.Social.Media.trending_links(unique_sharers_weight: 10.0)

    #   diverse1 = Enum.find(results, &String.contains?(&1.path, "diverse1"))
    #   popular = Enum.find(results, &String.contains?(&1.path, "popular"))

    #   # diverse1 has 2 sharers, popular has 1 sharer
    #   # With high weight, diversity should win
    #   diverse1_index = Enum.find_index(results, &(&1 == diverse1))
    #   popular_index = Enum.find_index(results, &(&1 == popular))

    #   assert diverse1_index < popular_index
    # end

    test "respects limit option" do
      # Create multiple different links
      user = Fake.fake_user!()

      Enum.each(1..10, fn i ->
        post =
          fake_post!(user, "public", %{
            post_content: %{html_body: "Link https://example.com/link#{i}"}
          })

        {:ok, _} = Boosts.boost(user, post)
      end)

      results = Bonfire.Social.Media.trending_links(limit: 3)
      assert length(results) <= 3
    end

    test "respects time_limit option and filters old posts", %{posts: posts} do
      # Default is 7 days, old_post is 10 days old - should be filtered out
      results =
        Bonfire.Social.Media.trending_links(time_limit: 7)
        |> flood("Results with 7-day time limit")

      old_links = Enum.filter(results, &String.contains?(&1.path, "old"))

      # Debug: print ULIDs and their decoded timestamps
      # flood("\nULID debug for old post and trending results:")
      # old_post = posts.old_post
      # old_ulid = old_post.id
      # old_link = old_links
      # |> flood("Old links found")
      # |> List.first()

      # old_link.newest_activity_id
      # |> DatesTimes.to_date_time()
      # |> flood("Old link datetime")

      assert length(old_links) == 0

      # With 30 day window, should include old post
      results_long = Bonfire.Social.Media.trending_links(time_limit: 30)
      old_links_long = Enum.filter(results_long, &String.contains?(&1.path, "old"))
      assert length(old_links_long) > 0
    end

    test "cache reset clears cached results" do
      # First call populates cache
      results1 = Bonfire.Social.Media.trending_links(limit: 10)
      assert is_list(results1)

      # Reset cache
      Bonfire.Social.Media.trending_links_reset(limit: 10)
      # Create new link after reset
      user = Fake.fake_user!()

      new_post =
        fake_post!(user, "public", %{
          post_content: %{html_body: "Brand new https://example.com/articleII"}
        })

      {:ok, _} = Boosts.boost(user, new_post)

      # After reset, fresh query should pick up new data
      results2 = Bonfire.Social.Media.trending_links(limit: 10)
      assert is_list(results2)
      assert Enum.any?(results2, &String.contains?(&1.path, "articleII"))
    end

    test "handles posts without boosts" do
      Bonfire.Social.Media.trending_links_reset(limit: 11)

      user = Fake.fake_user!()

      fake_post!(user, "public", %{
        post_content: %{html_body: "Unboosted link https://example.com/article2"}
      })

      results = Bonfire.Social.Media.trending_links(limit: 11)
      assert is_list(results)

      # Links without boosts should have 0 boost_count
      article2 = Enum.find(results, &String.contains?(&1.path, "article2"))

      if article2 do
        assert article2.boost_count >= 0
      end
    end

    test "includes object_count in results", %{results: results} do
      assert article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
      # article1 was shared twice (post1 and post2)
      assert Map.has_key?(article1, :object_count)
      assert article1.object_count == 2
    end

    test "calculates trending_score for article1 with shared fixture data" do
      # article1: shared by user1 and user2 (2 shares), boosted 3 times, 2 replies, 2 likes
      # weights: shares=4, boosts=2, likes=1, replies=3
      # object_count = 2, boost_count = 3, like_count = 2, reply_count = 2
      # trending_score = 2*4 + 3*2 + 2*1 + 2*3 = 8 + 6 + 2 + 6 = 22
      results = Bonfire.Social.Media.trending_links(sort_by: :trending_score)
      article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
      assert article1
      assert article1.trending_score == Decimal.new("22")
    end

    test "sorts by engagement with default weighting", %{results: results} do
      # article1 should be first (3 boosts + 2 sharers + 2 replies + 2 likes)
      # article2 should be second (1 boost + 1 sharer + 1 reply + 1 like)
      assert length(results) >= 2

      first = List.first(results)
      assert String.contains?(first.path, "article1")
      assert first.boost_count >= 3
      assert first.reply_count == Decimal.new("2")
      assert first.like_count == Decimal.new("2")
      assert first.object_count == 2
    end
  end

  describe "with custom test data" do
    setup do
      setup_url_mocks()
      :ok
    end

    # test "sorting respects unique_sharers_weight option" do
    #   Bonfire.Social.Media.trending_links_reset()

    #   user1 = Fake.fake_user!()
    #   user2 = Fake.fake_user!()
    #   user3 = Fake.fake_user!()

    #   # Create a post with many boosts but one sharer
    #   popular_post =
    #     fake_post!(user1, "public", %{
    #       post_content: %{html_body: "Very popular https://example.com/popular"}
    #     })

    #   # Add 10 boosts from same user
    #   Enum.each(1..10, fn _ ->
    #     Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], true)
    #     {:ok, _} = Boosts.boost(user2, popular_post)
    #   end)

    #   # Create posts with less boosts but more unique sharers (using different URL to avoid collision)
    #   post_a =
    #     fake_post!(user1, "public", %{
    #       post_content: %{html_body: "Diverse https://example.com/diverse1"}
    #     })

    #   post_b =
    #     fake_post!(user2, "public", %{
    #       post_content: %{html_body: "Also diverse https://example.com/diverse1"}
    #     })

    #   {:ok, _} = Boosts.boost(user3, post_a)
    #   {:ok, _} = Boosts.boost(user1, post_b)

    #   # With high weight on unique sharers, diverse1 should rank higher
    #   results = Bonfire.Social.Media.trending_links(unique_sharers_weight: 10.0)

    #   diverse1 = Enum.find(results, &String.contains?(&1.path, "diverse1"))
    #   popular = Enum.find(results, &String.contains?(&1.path, "popular"))

    #   # diverse1 has 2 sharers, popular has 1 sharer
    #   # With high weight, diversity should win
    #   diverse1_index = Enum.find_index(results, &(&1 == diverse1))
    #   popular_index = Enum.find_index(results, &(&1 == popular))

    #   assert diverse1_index < popular_index
    # end

    test "cache reset clears cached results" do
      # First call populates cache
      results1 = Bonfire.Social.Media.trending_links()
      assert is_list(results1)

      # Reset cache
      Bonfire.Social.Media.trending_links_reset()

      # Create new link after reset
      user = Fake.fake_user!()

      new_post =
        fake_post!(user, "public", %{
          post_content: %{html_body: "Brand new https://example.com/brandnew"}
        })

      {:ok, _} = Boosts.boost(user, new_post)

      # After reset, fresh query should pick up new data
      results2 = Bonfire.Social.Media.trending_links()
      assert is_list(results2)
    end

    test "handles no links gracefully" do
      Bonfire.Social.Media.trending_links_reset()

      # Create posts without links
      user = Fake.fake_user!()

      fake_post!(user, "public", %{
        post_content: %{html_body: "No links here, just text"}
      })

      # Should not crash
      results = Bonfire.Social.Media.trending_links()
      assert is_list(results)
    end

    test "handles posts without boosts" do
      Bonfire.Social.Media.trending_links_reset()

      user = Fake.fake_user!()

      fake_post!(user, "public", %{
        post_content: %{html_body: "Unboosted link https://example.com/unboosted"}
      })

      results = Bonfire.Social.Media.trending_links()
      assert is_list(results)

      # Links without boosts should have 0 boost_count
      unboosted = Enum.find(results, &String.contains?(&1.path, "unboosted"))

      if unboosted do
        assert unboosted.boost_count >= 0
      end
    end

    test "returns empty list when no trending links exist" do
      Bonfire.Social.Media.trending_links_reset()

      # Test with limit: 0 to get empty list
      results = Bonfire.Social.Media.trending_links(limit: 0)
      assert results == []
    end

    test "handles custom cache_ttl option" do
      Bonfire.Social.Media.trending_links_reset()

      # Test that custom TTL doesn't break functionality
      results = Bonfire.Social.Media.trending_links(cache_ms: 5000)
      assert is_list(results)
    end

    test "respects limit option, and paginates trending links with after cursor" do
      Bonfire.Social.Media.trending_links_reset()

      user = Fake.fake_user!()
      # Create 10 posts with unique links
      Enum.each(1..10, fn i ->
        post =
          fake_post!(user, "public", %{
            post_content: %{html_body: "Link https://example.com/page#{i}"}
          })

        {:ok, _} = Boosts.boost(user, post)
      end)

      # Page 1
      page1 = Bonfire.Social.Media.list_trending_paginated(limit: 3)
      assert is_map(page1)
      assert is_list(page1.edges)
      assert length(page1.edges) <= 3
      assert Map.has_key?(page1, :page_info)
      after_cursor = page1.page_info.end_cursor
      assert after_cursor

      # Page 2
      page2 = Bonfire.Social.Media.list_trending_paginated(limit: 3, after: after_cursor)
      assert is_map(page2)
      assert is_list(page2.edges)
      assert length(page2.edges) <= 3
      # Should not duplicate first page
      page1_paths = Enum.map(page1.edges, & &1.path)
      page2_paths = Enum.map(page2.edges, & &1.path)
      assert MapSet.disjoint?(MapSet.new(page1_paths), MapSet.new(page2_paths))
    end
  end
end
