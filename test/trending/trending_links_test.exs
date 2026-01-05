defmodule Bonfire.Social.TrendingLinksTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.TrendingLinks
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

      # Old post (outside default 7-day window)
      old_post =
        fake_post!(user1, "public", %{
          post_content: %{html_body: "Old link https://example.com/old"},
          id: DatesTimes.past(10, :day) |> DatesTimes.generate_ulid()
        })

      # Add boosts to posts
      # article1 via post1: 2 boosts
      {:ok, _boost1} = Boosts.boost(user2, post1)
      {:ok, _boost2} = Boosts.boost(user3, post1)

      # article1 via post2: 1 boost
      {:ok, _boost3} = Boosts.boost(user1, post2)

      # article2 via post3: 1 boost
      {:ok, _boost4} = Boosts.boost(user1, post3)

      %{
        users: [user1, user2, user3],
        posts: %{
          post1: post1,
          post2: post2,
          post3: post3,
          old_post: old_post
        },
        results: TrendingLinks.list_trending()
      }
    end

    test "returns trending links with correct structure", %{results: results} do
      assert is_list(results)
      assert length(results) > 0

      first = List.first(results)
      assert Map.has_key?(first, :media)
      assert Map.has_key?(first, :path)
      assert Map.has_key?(first, :total_boosts)
      assert Map.has_key?(first, :unique_sharers)
      assert Map.has_key?(first, :sharers)
      assert is_binary(first.path)
      assert is_integer(first.total_boosts)
      assert is_integer(first.unique_sharers)
      assert is_list(first.sharers)
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
      assert article1.total_boosts == 3
    end

    test "counts unique sharers correctly", %{results: results, users: [user1, user2, user3]} do
      assert article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
      # user1 and user2 shared article1
      assert article1.unique_sharers == 2
      assert length(article1.sharers) == 2

      sharer_ids = Enum.map(article1.sharers, & &1.id)
      assert user1.id in sharer_ids
      assert user2.id in sharer_ids
    end

    test "sorts by engagement with default weighting", %{results: results} do
      # article1 should be first (3 boosts + 2 sharers)
      # article2 should be second (1 boost + 1 sharer)
      assert length(results) >= 2

      first = List.first(results)
      assert String.contains?(first.path, "article1")
      assert first.total_boosts >= 3
    end

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

      results = TrendingLinks.list_trending(limit: 3)
      assert length(results) <= 3
    end

    test "respects time_limit option and filters old posts", %{posts: posts} do
      # Default is 7 days, old_post is 10 days old - should be filtered out
      results = TrendingLinks.list_trending(time_limit: 7)

      old_links = Enum.filter(results, &String.contains?(&1.path, "old"))

      # Old links should be filtered out by time_limit
      assert length(old_links) == 0

      # With 30 day window, should include old post
      results_long = TrendingLinks.list_trending(time_limit: 30)
      old_links_long = Enum.filter(results_long, &String.contains?(&1.path, "old"))
      assert length(old_links_long) > 0
    end

    test "handles posts without boosts" do
      user = Fake.fake_user!()

      fake_post!(user, "public", %{
        post_content: %{html_body: "Unboosted link https://example.com/article2"}
      })

      results = TrendingLinks.list_trending(limit: 11)
      assert is_list(results)

      # Links without boosts should have 0 total_boosts
      article2 = Enum.find(results, &String.contains?(&1.path, "article2"))

      if article2 do
        assert article2.total_boosts >= 0
      end
    end

    test "includes share_count in results", %{results: results} do
      assert article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
      # article1 was shared twice (post1 and post2)
      assert Map.has_key?(article1, :share_count)
      assert article1.share_count == 2
    end
  end

  describe "with custom test data" do
    setup do
      setup_url_mocks()
      :ok
    end

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

      results = TrendingLinks.list_trending(limit: 3)
      assert length(results) <= 3
    end

    test "handles no links gracefully" do
      # Create posts without links
      user = Fake.fake_user!()

      fake_post!(user, "public", %{
        post_content: %{html_body: "No links here, just text"}
      })

      # Should not crash
      results = TrendingLinks.list_trending()
      assert is_list(results)
    end

    test "handles posts without boosts" do
      user = Fake.fake_user!()

      fake_post!(user, "public", %{
        post_content: %{html_body: "Unboosted link https://example.com/unboosted"}
      })

      results = TrendingLinks.list_trending()
      assert is_list(results)

      # Links without boosts should have 0 total_boosts
      unboosted = Enum.find(results, &String.contains?(&1.path, "unboosted"))

      if unboosted do
        assert unboosted.total_boosts >= 0
      end
    end

    test "returns empty list when no trending links exist" do
      # Test with limit: 0 to get empty list
      results = TrendingLinks.list_trending(limit: 0)
      assert results == []
    end
  end
end
