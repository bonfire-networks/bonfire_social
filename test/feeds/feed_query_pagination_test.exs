defmodule Bonfire.Social.FeedPaginationTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake
  import Ecto.Query

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Posts
  alias Needle.Pointer

  test "return: :query returns an Ecto.Query struct" do
    # Get a query using the return: :query option
    query = FeedLoader.feed(:local, return: :query)

    # Test that it returns an Ecto.Query
    assert %Ecto.Query{} = query

    # Convert query to string for inspection
    query_string = Inspect.Ecto.Query.to_string(query)

    # Check for expected query components
    assert query_string =~ "from f0 in Bonfire.Data.Social.FeedPublish"
    assert query_string =~ "join: a1 in Bonfire.Data.Social.Activity,\n  as: :activity,"
    assert query_string =~ "preload: ["

    # Should have ordering
    assert query_string =~ "order_by: [desc: a1.id]"
  end

  describe "feed pagination with deferred join" do
    setup do
      # Create a user
      user = fake_user!("pagination_tester")

      # Create a large number of posts
      posts =
        for i <- 1..20 do
          fake_post!(user, "public", %{
            post_content: %{
              name: "Test post #{i}",
              html_body: "Content for post #{i}"
            }
          })
        end

      # Save the original config
      original_config = Config.get([Bonfire.Social.Feeds, :query_with_deferred_join])

      # Ensure deferred join is enabled for these tests
      Config.put([Bonfire.Social.Feeds, :query_with_deferred_join], true)

      # Return the original config to be used in on_exit
      on_exit(fn ->
        Config.put([Bonfire.Social.Feeds, :query_with_deferred_join], original_config)
      end)

      # Return the context for tests
      %{
        user: user,
        posts: posts
      }
    end

    test "works with default settings", %{
      user: user,
      posts: posts
    } do
      # Get the first page of posts
      feed = FeedLoader.feed(:custom, %{}, current_user: user, limit: 5)

      # Ensure we got some results
      assert length(feed.edges) > 0
      # Should be limited to 5
      assert length(feed.edges) <= 5
      # Should have pagination info
      assert feed.page_info
      assert feed.page_info.end_cursor
    end

    test "correctly handles empty results from deferred join", %{
      user: user
    } do
      # Force an empty result set by using a filter that won't match anything
      feed =
        FeedLoader.feed(
          :custom,
          %{tags: ["nonexistent_tag"]},
          current_user: user,
          limit: 5,
          query_with_deferred_join: true
        )

      # Should have empty edges
      assert feed.edges == []
    end

    test "has correct query structure and pagination behaviour", %{user: user} do
      # Set up common options
      opts = [
        current_user: user,
        query_with_deferred_join: true,
        limit: 5,
        #  to avoid deduping messing with the count
        show_objects_only_once: false
      ]

      # PART 1: Verify the structure of the first page query
      # -----------------------------------------------------
      query = FeedLoader.feed(:local, opts ++ [return: :query])

      assert %Ecto.Query{} = query
      query_string = Inspect.Ecto.Query.to_string(query)

      # Verify query structure
      assert query_string =~ "from f0 in Bonfire.Data.Social.FeedPublish"
      assert query_string =~ " in subquery(from "
      assert query_string =~ "preload: ["
      assert query_string =~ "order_by: [desc: a1.id]"

      # First page should have a limit but not cursor-based filtering
      assert query_string =~ "limit: ^6"
      refute query_string =~ "where: (a1.id < ^"

      # PART 2: Execute the first page query and get pagination info
      # -----------------------------------------------------
      assert %{edges: first_edges, page_info: %{end_cursor: after_cursor}} =
               FeedLoader.feed_many_paginated(query, %{}, opts)

      # Verify first page results
      assert is_list(first_edges)
      assert length(first_edges) > 0
      # Should respect the limit
      assert length(first_edges) <= 5
      assert is_binary(after_cursor)

      # PART 3: Verify the structure of the second page query
      # -----------------------------------------------------
      query2 =
        FeedLoader.feed(
          :local,
          opts ++
            [
              return: :query,
              after: after_cursor
            ]
        )

      assert %Ecto.Query{} = query2
      query2_string = Inspect.Ecto.Query.to_string(query2)

      # Verify second page query structure
      assert query2_string =~ " in subquery(from"
      assert query_string =~ "order_by: [desc: a1.id]"
      # Second page should have cursor-based filtering
      assert query2_string =~ "limit: ^6"
      assert query2_string =~ "where: (a1.id < ^\""
      # TODO: The ID corresponding to the cursor value should be in the query
      # assert query2_string =~ after_cursor

      # PART 4: Execute the second page query and verify results
      # -----------------------------------------------------
      assert %{edges: second_edges, page_info: _} =
               FeedLoader.feed_many_paginated(query2, %{}, opts)

      # Verify second page results
      assert is_list(second_edges)
      assert length(second_edges) > 0
      # Should respect the limit
      assert length(second_edges) <= 5

      # PART 5: Verify pagination works correctly (no overlap between pages)
      # -----------------------------------------------------
      # Get IDs from both pages
      first_ids = Enum.map(first_edges, fn edge -> edge.activity.id end)
      second_ids = Enum.map(second_edges, fn edge -> edge.activity.id end)

      # There should be no overlap in IDs between pages
      common_ids = MapSet.intersection(MapSet.new(first_ids), MapSet.new(second_ids))
      assert MapSet.size(common_ids) == 0, "Expected no overlap between page 1 and page 2"

      # PART 6: Verify we can navigate through the high-level API as well
      # -----------------------------------------------------
      api_first_page = FeedLoader.feed(:local, %{}, opts)

      # Verify API results match query results
      assert length(api_first_page.edges) == length(first_edges)

      api_second_page =
        FeedLoader.feed(
          :local,
          %{},
          opts ++
            [after: api_first_page.page_info.end_cursor]
        )

      # Verify API results match query results
      assert length(api_second_page.edges) == length(second_edges)

      # Again ensure no overlap
      api_first_ids = Enum.map(api_first_page.edges, fn edge -> edge.activity.id end)
      api_second_ids = Enum.map(api_second_page.edges, fn edge -> edge.activity.id end)
      api_common_ids = MapSet.intersection(MapSet.new(api_first_ids), MapSet.new(api_second_ids))
      assert MapSet.size(api_common_ids) == 0, "Expected no overlap between API page 1 and page 2"
    end
  end

  test "attempts pagination to next window before falling back to non-deferred query" do
    limit = 4
    user = fake_user!()
    other_user = fake_user!()

    # Use a unique tag to ensure we control the results
    unique_tag = "next_window_test"

    # Create posts with this tag that should appear in later windows
    tagged_posts =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Next Window Test #{i}",
            # Adding the tag in content
            html_body: "Content with ##{unique_tag}"
          }
        })
      end

    # Create (more recent) posts that would appear in the first window but won't be included by boundaries
    for i <- 1..(limit * 2 + 1) do
      fake_post!(other_user, "mentions", %{
        post_content: %{
          name: "First Window Test #{i}",
          html_body: "Hidden Content"
        }
      })
    end

    # Get the query with return: :query to inspect it
    first_window_query =
      FeedLoader.feed(
        :explore,
        %{},
        current_user: user,
        limit: limit,
        query_with_deferred_join: true,
        return: :query
      )

    # Verify first window query structure
    assert %Ecto.Query{} = first_window_query
    query_string = Inspect.Ecto.Query.to_string(first_window_query)

    # Should have a subquery with deferred join
    assert query_string =~ " in subquery(from"
    assert query_string =~ "order_by: [desc:"
    assert query_string =~ "limit: ^#{limit + 1}"

    # Execute the query to simulate first window being empty
    assert %{edges: edges, page_info: %{end_cursor: next_cursor}} =
             FeedLoader.feed_many_paginated(first_window_query, %{},
               current_user: user,
               limit: limit,
               query_with_deferred_join: true,
               # infinite_pages: true,
               #  to avoid deduping messing with the count
               show_objects_only_once: false
             )

    # Will be empty because our tagged posts are not in first window
    refute FeedLoader.feed_contains?(edges, "next_window_test")
    refute FeedLoader.feed_contains?(edges, "First Window Test")
    assert edges == []

    deferred_join_multiply_limit = 2

    # Now get the next window query
    next_window_query =
      FeedLoader.feed(
        :explore,
        %{},
        current_user: user,
        limit: limit,
        query_with_deferred_join: true,
        return: :query,
        # deferred_join_offset: deferred_join_multiply_limit * limit,
        deferred_join_multiply_limit: deferred_join_multiply_limit
      )

    # Verify next window query structure
    assert %Ecto.Query{} = next_window_query
    next_query_string = Inspect.Ecto.Query.to_string(next_window_query)

    # Should still have a subquery structure
    assert next_query_string =~ " in subquery(from"

    # Should offset limit but NOT have cursor-based filtering
    assert next_query_string =~ "offset: ^#{deferred_join_multiply_limit * limit}"
    refute next_query_string =~ "where: (a1.id < ^"

    # Should have larger limit (multiply_limit: 3)
    # The limit parameter will be bound
    assert next_query_string =~ "limit: ^#{limit * deferred_join_multiply_limit * 2 + 1}"
    # but not in outer query
    assert next_query_string =~ "limit: ^#{limit + 1}"

    # Execute the next window query - should find our tagged posts
    next_window_results =
      FeedLoader.feed_many_paginated(next_window_query, %{},
        current_user: user,
        limit: limit,
        after: next_cursor,
        query_with_deferred_join: true,
        deferred_join_multiply_limit: 3,
        #  to avoid deduping messing with the count
        show_objects_only_once: false
      )

    assert %{edges: next_edges} = next_window_results
    assert length(next_edges) > 0
    assert FeedLoader.feed_contains?(next_edges, "next_window_test")

    # Use the high-level API to test the full flow
    complete_feed =
      FeedLoader.feed(
        :explore,
        %{tags: unique_tag},
        current_user: user,
        limit: limit,
        query_with_deferred_join: true,
        #  to avoid deduping messing with the count
        show_objects_only_once: false
      )

    # Should find our tagged posts despite being in a later window
    assert length(complete_feed.edges) == limit

    # Check the content contains our tag
    assert FeedLoader.feed_contains?(complete_feed.edges, "next_window_test")
    refute FeedLoader.feed_contains?(complete_feed.edges, "First Window Test")
  end

  #  not needed because the query already only uses necessary joins
  @tag :todo
  test "optimizes the feed query" do
    # Arrange: Create the exact query as specified
    user_query = test_query()

    # Act: Optimize the query
    optimized_query = EctoSparkles.remove_unused_joins(user_query)
    optimized_string = Inspect.Ecto.Query.to_string(optimized_query)

    # Assert: Check the actual resulting query string
    assert optimized_string =~ "from p0 in Needle.Pointer"
    assert optimized_string =~ "left_join: a1 in assoc(p0, :activity)"
    assert optimized_string =~ "join: f2 in subquery("
    assert optimized_string =~ "on: f2.id == p0.id"
    assert optimized_string =~ "where: is_nil(p0.deleted_at)"
    assert optimized_string =~ "order_by: [desc: a1.id]"
    assert optimized_string =~ "limit: ^41"
    assert optimized_string =~ "offset: ^0"
    assert optimized_string =~ "select: p0"
    # refute optimized_string =~ ":peered"
  end

  # The exact subquery provided by the user
  defp test_query do
    from f0 in Bonfire.Data.Social.FeedPublish,
      as: :main_object,
      join: a1 in Bonfire.Data.Social.Activity,
      as: :activity,
      on: a1.id == f0.id,
      left_join: p2 in Needle.Pointer,
      as: :activity_pointer,
      on: a1.object_id != a1.id and p2.id == a1.id,
      join: p3 in Needle.Pointer,
      as: :object,
      on:
        p3.id == a1.object_id and is_nil(p3.deleted_at) and
          p3.table_id not in ^["6R1VATEMESAGEC0MMVN1CAT10N"],
      left_join: s4 in assoc(a1, :subject),
      as: :subject,
      left_join: c5 in assoc(s4, :character),
      as: :subject_character,
      left_join: p6 in assoc(c5, :peered),
      as: :subject_peered,
      left_join: p7 in assoc(p3, :peered),
      as: :object_peered,
      where: a1.id > ^"01HWJ60VT79357QBDB3KKW2EVM",
      where:
        is_nil(p2.deleted_at) and
          (is_nil(p2.table_id) or p2.table_id not in ^["6R1VATEMESAGEC0MMVN1CAT10N"]),
      where:
        (f0.feed_id == ^"3SERSFR0MY0VR10CA11NSTANCE" or (is_nil(p6.id) and is_nil(p7.id))) and
          a1.subject_id != ^"1ACT1V1TYPVBREM0TESFETCHER",
      where:
        a1.verb_id not in ^[
          "11KES1ND1CATEAM11DAPPR0VA1",
          "20SVBSCR1BET0THE0VTPVT0F1T",
          "7PDATETHESTATVS0FS0METH1NG",
          "71AGSPAM0RVNACCEPTAB1E1TEM",
          "40NTACTW1THAPR1VATEMESSAGE"
        ],
      distinct: [desc: a1.id],
      select: [:id]
  end
end
