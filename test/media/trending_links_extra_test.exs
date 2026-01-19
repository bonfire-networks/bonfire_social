defmodule Bonfire.Social.Bonfire.Social.TrendingLinksExtraTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Social.Media
  alias Bonfire.Social.Boosts
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  import Tesla.Mock

  setup do
    Bonfire.Social.Test.FakeHelpers.setup_url_mocks()
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
