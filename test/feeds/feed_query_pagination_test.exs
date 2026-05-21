defmodule Bonfire.Social.FeedPaginationTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Posts.Fake
  import Ecto.Query

  alias Bonfire.Boundaries.Acls
  alias Bonfire.Boundaries.Grants
  alias Bonfire.Data.Social.FeedPublish
  alias Bonfire.Social.FeedLoader

  defp activity_ids(edges), do: Enum.map(edges, & &1.activity.id)

  defp publish_to_local_feed(post) do
    {:ok, _published} =
      repo().upsert(
        Ecto.Changeset.cast(
          %FeedPublish{},
          %{feed_id: local_feed_id(), id: post.id},
          [:feed_id, :id]
        )
      )

    post
  end

  defp local_feed_id,
    do: Bonfire.Boundaries.Circles.get_id(:local) || "3SERSFR0MY0VR10CA11NSTANCE"

  defp with_pagination_hard_max_limit(limit) do
    key = [:bonfire, :pagination_hard_max_limit]
    previous = Process.get(key)

    Process.put(key, limit)

    on_exit(fn ->
      if is_nil(previous),
        do: Process.delete(key),
        else: Process.put(key, previous)
    end)
  end

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
    assert query_string =~ "f0.feed_id == ^\"3SERSFR0MY0VR10CA11NSTANCE\""
    refute query_string =~ "is_nil(c5.id) or is_nil(p6.peer_id)"
  end

  test "deferred join load-more offset skips the effective first join window" do
    with_pagination_hard_max_limit(1000)

    limit = 20

    query_string =
      FeedLoader.feed(:local,
        limit: limit,
        query_with_deferred_join: true,
        deferred_join_multiply_limit: 4,
        return: :query,
        preload: false
      )
      |> Inspect.Ecto.Query.to_string()

    assert query_string =~ "limit: ^#{limit * 32 + 1}"
    assert query_string =~ "limit: ^#{limit + 1}"
    assert query_string =~ "offset: ^#{limit * 32}"
    refute query_string =~ "offset: ^#{limit * 2}"

    query_string =
      FeedLoader.feed(:local,
        limit: limit,
        query_with_deferred_join: true,
        deferred_join_multiply_limit: 8,
        return: :query,
        preload: false
      )
      |> Inspect.Ecto.Query.to_string()

    assert query_string =~ "limit: ^#{limit * 32 + 1}"
    assert query_string =~ "limit: ^#{limit + 1}"
    assert query_string =~ "offset: ^#{limit * 32}"
    refute query_string =~ "offset: ^#{limit * 2}"
  end

  test "local feed defaults to a wider deferred join window" do
    with_pagination_hard_max_limit(1000)

    limit = 20

    query_string =
      FeedLoader.feed(:local,
        limit: limit,
        query_with_deferred_join: true,
        return: :query,
        preload: false
      )
      |> Inspect.Ecto.Query.to_string()

    assert query_string =~ "limit: ^#{limit * 32 + 1}"
    assert query_string =~ "limit: ^#{limit + 1}"
    refute query_string =~ "offset: ^#{limit * 16}"
  end

  test "anonymous local first page includes guest-visible custom ACLs" do
    with_pagination_hard_max_limit(500)

    limit = 1
    user = fake_user!()
    unique_tag = "guest_custom_acl_#{System.unique_integer([:positive])}"

    custom_visible =
      user
      |> fake_post!("private", %{
        post_content: %{
          name: "Guest-visible custom ACL",
          html_body: "Custom ACL content ##{unique_tag}"
        }
      })
      |> publish_to_local_feed()

    {:ok, acl} = Acls.get_or_create_object_custom_acl(custom_visible, user)
    assert [_see, _read] = Grants.grant(:guest, acl, [:see, :read], true)

    query_string =
      FeedLoader.feed(:local,
        limit: limit,
        query_with_deferred_join: true,
        return: :query,
        preload: false
      )
      |> Inspect.Ecto.Query.to_string()

    assert query_string =~ "Bonfire.Data.AccessControl.Grant"
    assert query_string =~ "deferred_inner_guest_visible_acl"

    feed =
      FeedLoader.feed(:local, %{},
        limit: limit,
        query_with_deferred_join: true,
        show_objects_only_once: false,
        preload: false
      )

    assert length(feed.edges) == limit
    assert FeedLoader.feed_contains?(feed.edges, custom_visible)
  end

  test "deferred join load-more offset uses nested pagination limit" do
    with_pagination_hard_max_limit(1000)

    limit = 20

    query_string =
      FeedLoader.feed(:local,
        paginate: [limit: limit, return: :query],
        query_with_deferred_join: true,
        deferred_join_multiply_limit: 4,
        return: :query,
        preload: false
      )
      |> Inspect.Ecto.Query.to_string()

    assert query_string =~ "limit: ^#{limit * 32 + 1}"
    assert query_string =~ "offset: ^#{limit * 32}"
    refute query_string =~ "offset: ^60"
  end

  test "guest local feed origin filter keeps local feed membership fast path" do
    query = FeedLoader.feed(:local, return: :query, preload: false)

    query_string = Inspect.Ecto.Query.to_string(query)

    assert query_string =~ "feed_id == ^"
    refute query_string =~ "subject_peered"
    refute query_string =~ "object_peered"
  end

  test "authenticated local feed origin filter also includes visible local actor activities" do
    user = fake_user!("viewer")
    query = FeedLoader.feed(:local, return: :query, preload: false, current_user: user)

    query_string = Inspect.Ecto.Query.to_string(query)

    assert query_string =~ "feed_id == ^"
    assert query_string =~ " or "
    assert query_string =~ "subject_peered"
    assert query_string =~ "object_peered"

    assert query_string =~ "as: :subject_character" and
             query_string =~ "as: :subject_peered" and
             query_string =~ "as: :object_peered" and
             query_string =~ "is_nil(" and
             query_string =~ "peer_id"
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

    test "works with default settings", %{user: user} do
      # Get the first page of posts
      feed = FeedLoader.feed(:custom, %{}, current_user: user, limit: 5, preload: false)

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
        show_objects_only_once: false,
        preload: false
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
      refute query_string =~ "where: (f0.id < ^"

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
      assert query2_string =~ "where: (f0.id < ^\""
      # TODO: The ID corresponding to the cursor value should be in the query
      # assert query2_string =~ after_cursor

      expanded_window_query =
        FeedLoader.feed(
          :local,
          opts ++
            [
              return: :query,
              after: after_cursor,
              deferred_join_multiply_limit: 4
            ]
        )

      expanded_window_query_string = Inspect.Ecto.Query.to_string(expanded_window_query)

      assert expanded_window_query_string =~ "where: (f0.id < ^\""
      assert expanded_window_query_string =~ "limit: ^2561"
      assert expanded_window_query_string =~ "offset: ^0"
      refute expanded_window_query_string =~ "offset: ^20"

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

    test "nested paginator cursors expand the deferred join window without pre-offsetting", %{
      user: user
    } do
      opts = [
        current_user: user,
        query_with_deferred_join: true,
        limit: 5,
        show_objects_only_once: false,
        preload: false
      ]

      first_page = FeedLoader.feed(:local, %{}, opts)
      assert is_binary(first_page.page_info.end_cursor)

      nested_second_page =
        FeedLoader.feed(
          :local,
          %{},
          opts ++
            [
              paginate: [after: first_page.page_info.end_cursor, limit: 5],
              deferred_join_multiply_limit: 4
            ]
        )

      assert length(nested_second_page.edges) > 0

      first_ids = Enum.map(first_page.edges, & &1.activity.id)
      nested_second_ids = Enum.map(nested_second_page.edges, & &1.activity.id)
      overlap = MapSet.intersection(MapSet.new(first_ids), MapSet.new(nested_second_ids))

      assert MapSet.size(overlap) == 0,
             "Expected nested paginator load-more pages not to overlap, got #{inspect(MapSet.to_list(overlap))}"

      nested_after_query =
        FeedLoader.feed(
          :local,
          %{},
          opts ++
            [
              return: :query,
              paginate: [after: first_page.page_info.end_cursor, limit: 5, return: :query],
              deferred_join_multiply_limit: 4
            ]
        )

      nested_after_query_string = Inspect.Ecto.Query.to_string(nested_after_query)

      assert nested_after_query_string =~ "where:"
      assert nested_after_query_string =~ "limit: ^2561"
      assert nested_after_query_string =~ "offset: ^0"
      refute nested_after_query_string =~ "offset: ^20"
    end

    test "paginate false still disables pagination" do
      user = fake_user!()
      unique_tag = "paginate_false_#{System.unique_integer([:positive])}"

      for i <- 1..5 do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Paginate False #{i}",
            html_body: "Paginate false visible content #{i} ##{unique_tag}"
          }
        })
      end

      result =
        FeedLoader.feed(:custom, %{tags: [unique_tag]},
          current_user: user,
          query_with_deferred_join: false,
          paginate: false,
          limit: 1,
          show_objects_only_once: false,
          preload: false
        )

      assert is_list(result)
      assert length(result) >= 5
    end
  end

  test "cursor load-more skips a boundary-hidden deferred join window" do
    with_pagination_hard_max_limit(500)

    limit = 3
    user = fake_user!()
    other_user = fake_user!()
    unique_tag = "cursor_gap_#{System.unique_integer([:positive])}"

    older_public =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Older Gap Public #{i}",
            html_body: "Older visible content ##{unique_tag}"
          }
        })
      end

    hidden_private =
      for i <- 1..(limit * 6 + 1) do
        fake_post!(other_user, "mentions", %{
          post_content: %{
            name: "Hidden Gap Private #{i}",
            html_body: "Boundary hidden content ##{unique_tag}"
          }
        })
      end

    Enum.each(hidden_private, &publish_to_local_feed/1)

    newer_public =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Newer Gap Public #{i}",
            html_body: "Newer visible content ##{unique_tag}"
          }
        })
      end

    opts = [
      current_user: user,
      limit: limit,
      query_with_deferred_join: true,
      show_objects_only_once: false,
      preload: false
    ]

    first_page = FeedLoader.feed(:local, %{}, opts)
    assert length(first_page.edges) == limit
    assert Enum.all?(newer_public, &FeedLoader.feed_contains?(first_page.edges, &1))
    refute Enum.any?(hidden_private, &FeedLoader.feed_contains?(first_page.edges, &1))
    assert is_binary(first_page.page_info.end_cursor)

    second_page =
      FeedLoader.feed(:local, %{}, opts ++ [after: first_page.page_info.end_cursor])

    assert length(second_page.edges) == limit
    assert Enum.all?(older_public, &FeedLoader.feed_contains?(second_page.edges, &1))
    refute Enum.any?(hidden_private, &FeedLoader.feed_contains?(second_page.edges, &1))

    first_ids = Enum.map(first_page.edges, & &1.activity.id)
    second_ids = Enum.map(second_page.edges, & &1.activity.id)
    overlap = MapSet.intersection(MapSet.new(first_ids), MapSet.new(second_ids))

    assert MapSet.size(overlap) == 0,
           "Expected cursor load-more pages not to overlap, got #{inspect(MapSet.to_list(overlap))}"
  end

  test "top-level cursor survives nested paginate limit across multiple hidden windows" do
    with_pagination_hard_max_limit(500)

    limit = 3
    user = fake_user!()
    other_user = fake_user!()
    unique_tag = "mixed_cursor_gap_#{System.unique_integer([:positive])}"

    older_public =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Older Mixed Public #{i}",
            html_body: "Older mixed visible content ##{unique_tag}"
          }
        })
      end

    hidden_private =
      for i <- 1..(limit * 20) do
        fake_post!(other_user, "mentions", %{
          post_content: %{
            name: "Hidden Mixed Private #{i}",
            html_body: "Boundary hidden mixed content ##{unique_tag}"
          }
        })
      end

    newer_public =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Newer Mixed Public #{i}",
            html_body: "Newer mixed visible content ##{unique_tag}"
          }
        })
      end

    opts = [
      current_user: user,
      query_with_deferred_join: true,
      show_objects_only_once: false,
      preload: false
    ]

    first_page = FeedLoader.feed(:local, %{}, opts ++ [paginate: [limit: limit]])
    assert length(first_page.edges) == limit
    assert Enum.all?(newer_public, &FeedLoader.feed_contains?(first_page.edges, &1))

    second_page =
      FeedLoader.feed(
        :local,
        %{},
        opts ++
          [
            after: first_page.page_info.end_cursor,
            paginate: [limit: limit],
            deferred_join_multiply_limit: 4
          ]
      )

    assert length(second_page.edges) == limit
    assert Enum.all?(older_public, &FeedLoader.feed_contains?(second_page.edges, &1))
    refute Enum.any?(hidden_private, &FeedLoader.feed_contains?(second_page.edges, &1))

    overlap =
      MapSet.intersection(
        MapSet.new(activity_ids(first_page.edges)),
        MapSet.new(activity_ids(second_page.edges))
      )

    assert MapSet.size(overlap) == 0,
           "Expected mixed cursor/nested paginate pages not to overlap, got #{inspect(MapSet.to_list(overlap))}"
  end

  test "attempts pagination to next window before falling back to non-deferred query" do
    with_pagination_hard_max_limit(500)

    limit = 2
    user = fake_user!()
    other_user = fake_user!()
    initial_deferred_join_multiply_limit = 6

    # Use a unique tag to ensure we control the results
    unique_tag = "next_window_test_#{System.unique_integer([:positive])}"

    # Create posts with this tag that should appear in later windows
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
    for i <- 1..(limit * initial_deferred_join_multiply_limit + 1) do
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
    refute FeedLoader.feed_contains?(edges, unique_tag)
    refute FeedLoader.feed_contains?(edges, "First Window Test")
    assert edges == []

    deferred_join_multiply_limit = 4

    # Now get the next window query
    next_window_query =
      FeedLoader.feed(
        :explore,
        %{},
        current_user: user,
        limit: limit,
        query_with_deferred_join: true,
        return: :query,
        deferred_join_multiply_limit: deferred_join_multiply_limit
        # deferred_join_offset: deferred_join_multiply_limit * limit
      )

    # Verify next window query structure
    assert %Ecto.Query{} = next_window_query
    next_query_string = Inspect.Ecto.Query.to_string(next_window_query)

    # Should still have a subquery structure
    assert next_query_string =~ " in subquery(from"

    # Should offset limit but NOT have cursor-based filtering
    assert next_query_string =~ "offset: ^#{initial_deferred_join_multiply_limit * limit}"
    refute next_query_string =~ "where: (f0.id < ^"

    # Should have a larger limit, clamped to the minimum deferred join window.
    # The limit parameter will be bound
    assert next_query_string =~
             "limit: ^#{limit * initial_deferred_join_multiply_limit + 1}"

    # but not in outer query
    assert next_query_string =~ "limit: ^#{limit + 1}"

    # Execute the next window query - should find our tagged posts
    next_window_results =
      FeedLoader.feed_many_paginated(next_window_query, %{},
        current_user: user,
        limit: limit,
        after: next_cursor,
        query_with_deferred_join: true,
        deferred_join_multiply_limit: deferred_join_multiply_limit,
        #  to avoid deduping messing with the count
        show_objects_only_once: false,
        preload: false
      )

    assert %{edges: next_edges} = next_window_results
    assert length(next_edges) > 0
    assert FeedLoader.feed_contains?(next_edges, unique_tag)

    # Execute a normal query - should also find our tagged posts using the high-level API which automatically attempts to load next window or removed the deferred join if nothing is found the 2nd time
    automatic_next_window_results =
      FeedLoader.feed(:explore, %{},
        current_user: user,
        limit: limit,
        after: next_cursor,
        query_with_deferred_join: true,
        # deferred_join_multiply_limit: 3,
        #  to avoid deduping messing with the count
        show_objects_only_once: false,
        preload: false
      )

    assert %{edges: automatic_next_edges} = automatic_next_window_results
    assert length(automatic_next_edges) > 0
    assert FeedLoader.feed_contains?(automatic_next_edges, unique_tag)
  end

  test "refills an under-filled deferred join page before returning it" do
    with_pagination_hard_max_limit(500)

    limit = 4
    user = fake_user!()
    other_user = fake_user!()
    unique_tag = "underfilled_window_test_#{System.unique_integer([:positive])}"

    older_public =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Older visible refill #{i}",
            html_body: "Older visible refill ##{unique_tag}"
          }
        })
      end

    for i <- 1..(limit * 6 - 2) do
      fake_post!(other_user, "mentions", %{
        post_content: %{
          name: "Hidden first-window #{i}",
          html_body: "Hidden first-window content"
        }
      })
    end

    for i <- 1..2 do
      fake_post!(user, "public", %{
        post_content: %{
          name: "Newest visible partial #{i}",
          html_body: "Newest visible partial ##{unique_tag}"
        }
      })
    end

    %{edges: edges} =
      FeedLoader.feed(:explore, %{},
        current_user: user,
        limit: limit,
        query_with_deferred_join: true,
        show_objects_only_once: false,
        preload: false
      )

    assert length(edges) == limit
    assert Enum.any?(older_public, &FeedLoader.feed_contains?(edges, &1))
    refute FeedLoader.feed_contains?(edges, "Hidden first-window")
  end

  test "refills across a larger hidden deferred window before returning visible rows" do
    with_pagination_hard_max_limit(500)

    limit = 4
    user = fake_user!()
    other_user = fake_user!()
    unique_tag = "adaptive_refill_test_#{System.unique_integer([:positive])}"

    older_public =
      for i <- 1..limit do
        fake_post!(user, "public", %{
          post_content: %{
            name: "Older adaptive refill #{i}",
            html_body: "Older adaptive refill ##{unique_tag}"
          }
        })
      end

    hidden_rows = limit * 16 + 2

    for i <- 1..hidden_rows do
      fake_post!(other_user, "mentions", %{
        post_content: %{
          name: "Hidden adaptive-window #{i}",
          html_body: "Hidden adaptive-window content"
        }
      })
    end

    for i <- 1..1 do
      fake_post!(user, "public", %{
        post_content: %{
          name: "Newest adaptive partial #{i}",
          html_body: "Newest adaptive partial ##{unique_tag}"
        }
      })
    end

    %{edges: edges} =
      FeedLoader.feed(:explore, %{},
        current_user: user,
        limit: limit,
        query_with_deferred_join: true,
        show_objects_only_once: false,
        preload: false
      )

    assert length(edges) == limit
    assert Enum.any?(older_public, &FeedLoader.feed_contains?(edges, &1))
    assert FeedLoader.feed_contains?(edges, unique_tag)
    refute FeedLoader.feed_contains?(edges, "Hidden adaptive-window")
  end

  describe "reply_count sorting with exclude_activity_types: [:reply]" do
    setup do
      user = fake_user!("reply_sort_tester")
      replier = fake_user!("replier")
      unique_tag = "reply_sort_#{System.unique_integer([:positive])}"

      # Create 12 root posts (more than one page of 5)
      posts =
        for i <- 1..12 do
          fake_post!(user, "public", %{
            post_content: %{
              name: "Discussion #{i}",
              html_body: "Content for discussion #{i} ##{unique_tag}"
            }
          })
        end

      # Add replies to some posts so they have varying reply counts
      # Post 12 gets 5 replies, post 11 gets 4, ..., post 8 gets 1
      for {post, reply_count} <- Enum.zip(Enum.reverse(Enum.take(posts, -5)), 1..5) do
        for j <- 1..reply_count do
          fake_post!(replier, "public", %{
            post_content: %{html_body: "Reply #{j} to #{post.id}"},
            reply_to_id: post.id
          })
        end
      end

      %{user: user, posts: posts, unique_tag: unique_tag}
    end

    test "pagination has no overlap between pages", %{user: user, unique_tag: unique_tag} do
      opts = [
        current_user: user,
        limit: 5,
        show_objects_only_once: false,
        preload: false
      ]

      filters = %{
        sort_by: :reply_count,
        sort_order: :desc,
        exclude_activity_types: [:reply],
        tags: [unique_tag]
      }

      # First page
      first_page = FeedLoader.feed(:custom, filters, opts)
      assert length(first_page.edges) > 0
      assert first_page.page_info.end_cursor

      # Second page
      second_page =
        FeedLoader.feed(:custom, filters, opts ++ [after: first_page.page_info.end_cursor])

      assert length(second_page.edges) > 0

      # No overlap
      first_ids = Enum.map(first_page.edges, & &1.activity.id)
      second_ids = Enum.map(second_page.edges, & &1.activity.id)
      overlap = MapSet.intersection(MapSet.new(first_ids), MapSet.new(second_ids))

      assert MapSet.size(overlap) == 0,
             "Pages overlap on IDs: #{inspect(MapSet.to_list(overlap))}"
    end

    test "pagination returns all items across pages", %{user: user, unique_tag: unique_tag} do
      opts = [
        current_user: user,
        limit: 5,
        show_objects_only_once: false,
        preload: false
      ]

      filters = %{
        sort_by: :reply_count,
        sort_order: :desc,
        exclude_activity_types: [:reply],
        tags: [unique_tag]
      }

      all_ids =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            page_opts = if cursor, do: opts ++ [after: cursor], else: opts
            page = FeedLoader.feed(:custom, filters, page_opts)

            case page.edges do
              [] -> nil
              edges -> {edges, page.page_info.end_cursor || :done}
            end
        end)
        |> Enum.flat_map(fn edges -> Enum.map(edges, & &1.activity.id) end)

      # Should have 12 unique items (the root posts, no replies)
      assert length(Enum.uniq(all_ids)) == 12,
             "Expected 12 unique items across all pages, got #{length(Enum.uniq(all_ids))}"
    end
  end

  # not needed because the query already only uses necessary joins
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
