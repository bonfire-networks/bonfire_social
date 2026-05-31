# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.MastoApi.FeedBenchmarkTest do
    @moduledoc """
    Phase 0 benchmark (GRAPHQL_FIRST_MASTO_PLAN.md): cost of producing a feed via
    the DIRECT context path (A) vs current GraphQL+Dataloader (B) vs variant-D
    synchronous resolution from preloaded structs (D). Excluded from the normal
    suite (@tag :benchmark).

    Uses a `subjects`-filtered feed (queries activities by author, independent of
    async feed fan-out) so a deterministic N-item feed is available in tests.

    Run: MIX_ENV=test mix ecto.reset && \\
         WITH_AI=0 just test extensions/bonfire_social/test/api/masto_api/feed_benchmark_test.exs --only benchmark
    """
    use Bonfire.Social.MastoApiCase, async: false

    alias Bonfire.Me.Fake
    alias Bonfire.Posts
    alias Bonfire.Social.Likes
    alias Bonfire.API.MastoCompat.{FeedPipeline, BatchLoaders, Mappers}
    alias Bonfire.API.GraphQL.Schema

    @moduletag :benchmark
    @moduletag timeout: :infinity
    @feed_size 20

    @gql """
    query Feed($first: Int, $subjects: [String]) {
      feedActivities(first: $first, filter: {feedName: "user_activities", subjects: $subjects}) {
        edges {
          node {
            id
            date
            verb { verb }
            subject { ... on User { id profile { name summary } character { username } } }
            object { ... on Post { id postContent { name htmlBody summary } } }
            likedByMe
            boostedByMe
            bookmarkedByMe
            likeCount
            boostCount
            repliesCount
          }
        }
      }
    }
    """

    # Variant D: identical selection, against the preloaded feed field (synchronous resolution).
    @gql_d String.replace(@gql, "feedActivities(", "feedActivitiesPreloaded(")

    setup do
      Process.put(:feed_live_update_many_preload_mode, :inline)
      # test config caps default_pagination_limit at 2 (config/test.exs); raise it so
      # the feed returns a representative page (the explicit `first` isn't mapped to
      # opts[:limit], so the default applies — see feed_loader.ex:756).
      Bonfire.Common.Config.put(:default_pagination_limit, 50)
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      author = Fake.fake_user!()

      for i <- 1..@feed_size do
        {:ok, post} =
          Posts.publish(
            current_user: author,
            post_attrs: %{post_content: %{html_body: "benchmark post #{i} about #elixir"}},
            boundary: "public"
          )

        if rem(i, 3) == 0, do: {:ok, _} = Likes.like(viewer, post)
      end

      {:ok, viewer: viewer, subjects: [author.id]}
    end

    @tag :benchmark
    test "feed resolution: direct (A) vs GraphQL+Dataloader (B) vs preloaded (D)", ctx do
      %{viewer: viewer, subjects: subjects} = ctx
      limit = @feed_size
      a = fn -> variant_a(viewer, subjects, limit) end
      b = fn -> variant_gql(@gql, viewer, subjects, limit) end
      d = fn -> variant_gql(@gql_d, viewer, subjects, limit) end

      a_out = a.()
      b_out = b.()
      d_out = d.()
      assert is_list(a_out) and a_out != []
      assert is_list(b_out) and b_out != []
      assert is_list(d_out) and d_out != []

      IO.puts("\n=== DB query counts (one call) ===")
      IO.puts("A (direct):            #{count_queries(a)} queries, #{length(a_out)} items")
      IO.puts("B (graphql+dl):        #{count_queries(b)} queries, #{length(b_out)} items")
      IO.puts("D (graphql preloaded): #{count_queries(d)} queries, #{length(d_out)} items")

      IO.puts("\n=== Dataloader batch runs (one call) ===")
      bdb = absinthe_breakdown(b)
      bdd = absinthe_breakdown(d)
      IO.puts("B: op #{bdb.operation_ms} ms, #{bdb.dataloader_count} dataloader runs")
      IO.puts("D: op #{bdd.operation_ms} ms, #{bdd.dataloader_count} dataloader runs")

      IO.puts("\n=== Benchee (p50/p99) ===")

      Benchee.run(
        %{"A_direct" => a, "B_graphql" => b, "D_graphql_preloaded" => d},
        time: 5,
        warmup: 2,
        percentiles: [50, 99],
        print: [fast_warning: false],
        formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
      )
    end

    # Phase 2 gate (GRAPHQL_FIRST_MASTO_PLAN.md): persisted/precompiled documents only pay
    # off if per-request parse+validate is a meaningful fraction of the operation. Measure the
    # fixed cost (everything before Resolution) that a persisted DocumentProvider would skip,
    # against the full operation — both at n=20 (resolution-dominated) and n=1 (fixed-cost-dominated).
    @tag :benchmark
    test "Phase 2: parse+validate fixed cost vs full operation", ctx do
      %{viewer: viewer, subjects: subjects} = ctx
      context = Schema.context(%{current_user: viewer})

      measure = fn first ->
        opts = [variables: %{"first" => first, "subjects" => subjects}, context: context]
        full_pipeline = Absinthe.Pipeline.for_document(Schema, opts)

        parse_validate =
          Absinthe.Pipeline.before(full_pipeline, Absinthe.Phase.Document.Execution.Resolution)

        # correctness: the prefix yields a validated blueprint with no errors
        {:ok, %Absinthe.Blueprint{} = bp, _} = Absinthe.Pipeline.run(@gql, parse_validate)
        assert bp.execution.validation_errors in [nil, []]

        %{
          parse_validate: fn -> Absinthe.Pipeline.run(@gql, parse_validate) end,
          full: fn -> Absinthe.run(@gql, Schema, opts) end
        }
      end

      for first <- [1, @feed_size] do
        m = measure.(first)
        IO.puts("\n=== Phase 2 fixed-cost share (first: #{first}) ===")

        Benchee.run(
          %{"parse+validate only" => m.parse_validate, "full operation" => m.full},
          time: 3,
          warmup: 1,
          percentiles: [50, 99],
          print: [fast_warning: false, configuration: false, benchmarking: false]
        )
      end
    end

    # Phase 6/7 reality check (GRAPHQL_FIRST_MASTO_PLAN.md): the REST-on-GraphQL conversions
    # do Absinthe.run (resolve bonfire-shaped node) + from_graphql (map to Mastodon), which is
    # strictly more work than the direct path (structs -> mapper). Measure the real overhead
    # on `show_status` (single item) to validate the per-endpoint perf gate (p99 <= 1.3x direct)
    # BEFORE converting the hottest path (timelines).
    @status_query """
    query Status($id: ID!) {
      status(id: $id) {
        id
        object_id: objectId
        verb { verb }
        subject { ... on User { id character { username } profile { name summary } } }
        object {
          ... on Post {
            id
            post_content: postContent { name summary html_body: rawBody }
          }
        }
        media { id media_type: mediaType url description metadata }
        liked_by_me: likedByMe
        boosted_by_me: boostedByMe
        bookmarked_by_me: bookmarkedByMe
        replies_count: repliesCount
      }
    }
    """

    @tag :benchmark
    test "show_status: direct vs GraphQL-backed (Phase 6 overhead)", ctx do
      %{viewer: viewer, subjects: [author_id]} = ctx
      # use one of the seeded public posts
      {:ok, post} =
        Bonfire.Posts.read(hd(seeded_post_ids(author_id, viewer)), current_user: viewer)

      id = post.id

      direct = fn -> show_direct(id, viewer) end
      graphql = fn -> show_graphql(id, viewer) end

      assert is_map(direct.()) and is_map(graphql.())

      IO.puts("\n=== show_status DB queries (one call) ===")
      IO.puts("direct:  #{count_queries(direct)} queries")
      IO.puts("graphql: #{count_queries(graphql)} queries")

      IO.puts("\n=== show_status Benchee (p50/p99) ===")

      Benchee.run(
        %{"direct" => direct, "graphql" => graphql},
        time: 4,
        warmup: 2,
        percentiles: [50, 99],
        print: [fast_warning: false, configuration: false, benchmarking: false]
      )
    end

    defp seeded_post_ids(author_id, viewer) do
      %{edges: edges} =
        Bonfire.Social.FeedActivities.feed(:user_activities, %{subjects: [author_id]},
          current_user: viewer,
          paginate: %{first: 5}
        )

      edges |> Enum.map(&(&1.activity.object_id || &1.activity.id)) |> Enum.reject(&is_nil/1)
    end

    defp show_direct(id, viewer) do
      case Bonfire.Social.Objects.read(id,
             current_user: viewer,
             preload: FeedPipeline.single_status_preloads()
           ) do
        {:ok, %{activity: activity} = object} when is_map(activity) ->
          act = Map.put(activity, :object, object)
          ids = [Map.get(act, :object_id) || Map.get(act, :id)] |> Enum.reject(&is_nil/1)
          batch = BatchLoaders.load(viewer, ids) |> Keyword.put(:current_user, viewer)
          Mappers.Status.from_activity(act, batch)

        _ ->
          nil
      end
    end

    defp show_graphql(id, viewer) do
      {:ok, %{data: %{"status" => node}}} =
        Absinthe.run(@status_query, Schema,
          variables: %{"id" => id},
          context: Schema.context(%{current_user: viewer})
        )

      ids = [node["object_id"] || node["id"]] |> Enum.reject(&is_nil/1)
      batch = BatchLoaders.load(viewer, ids) |> Keyword.put(:current_user, viewer)
      Mappers.Status.from_graphql_activity(node, batch)
    end

    # Phase 7 gate: the timeline conversion runs feedActivitiesPreloaded with the FULL activity
    # selection (incl. the boost-only object.activity nesting) + from_graphql_activity. Measure
    # it vs the direct timeline path (FeedPipeline + from_activity) — the nesting is exactly what
    # blew the show_status gate, so this must be re-checked at the feed level.
    @feed_activity_query """
    query Feed($first: Int, $subjects: [String]) {
      feed: feedActivitiesPreloaded(first: $first, filter: {feedName: "user_activities", subjects: $subjects}) {
        edges {
          node {
            id
            object_id: objectId
            verb { verb }
            subject { ... on User { id character { username } profile { name summary } } }
            object {
              ... on Post {
                id
                post_content: postContent { name summary html_body: rawBody }
                media { id media_type: mediaType url description metadata }
                creator { ... on User { id character { username } profile { name summary } } }
              }
            }
            media { id media_type: mediaType url description metadata }
            liked_by_me: likedByMe
            boosted_by_me: boostedByMe
            bookmarked_by_me: bookmarkedByMe
            replies_count: repliesCount
          }
        }
      }
    }
    """

    @tag :benchmark
    test "timeline: direct vs GraphQL-backed (Phase 7 overhead)", ctx do
      %{viewer: viewer, subjects: subjects} = ctx

      direct = fn -> variant_a(viewer, subjects, @feed_size) end
      graphql = fn -> timeline_graphql(viewer, subjects, @feed_size) end

      assert length(direct.()) > 0 and length(graphql.()) > 0

      IO.puts("\n=== timeline DB queries (one call) ===")
      IO.puts("direct:  #{count_queries(direct)} queries, #{length(direct.())} items")
      IO.puts("graphql: #{count_queries(graphql)} queries, #{length(graphql.())} items")

      IO.puts("\n=== timeline Benchee (p50/p99) ===")

      Benchee.run(
        %{"direct" => direct, "graphql" => graphql},
        time: 4,
        warmup: 2,
        percentiles: [50, 99],
        print: [fast_warning: false, configuration: false, benchmarking: false]
      )
    end

    defp timeline_graphql(viewer, subjects, limit) do
      {:ok, %{data: %{"feed" => %{"edges" => edges}}}} =
        Absinthe.run(@feed_activity_query, Schema,
          variables: %{"first" => limit, "subjects" => subjects},
          context: Schema.context(%{current_user: viewer})
        )

      nodes = Enum.map(edges, & &1["node"])
      ids = nodes |> Enum.map(&(&1["object_id"] || &1["id"])) |> Enum.reject(&is_nil/1)
      batch = BatchLoaders.load(viewer, ids) |> Keyword.put(:current_user, viewer)

      Enum.flat_map(nodes, fn n ->
        case Mappers.Status.from_graphql_activity(n, batch) do
          m when is_map(m) -> [m]
          _ -> []
        end
      end)
    end

    # ---- variant A: direct context path (current production REST read) ----
    defp variant_a(viewer, subjects, limit) do
      params = %{
        filter: %{"feed_name" => "user_activities", "subjects" => subjects},
        first: limit
      }

      case FeedPipeline.load(params, viewer) do
        {:ok, activities, _page_info} ->
          object_ids = FeedPipeline.object_ids(activities)
          batch = Keyword.put(BatchLoaders.load(viewer, object_ids), :current_user, viewer)

          Enum.flat_map(activities, fn act ->
            case Mappers.Status.from_activity(act, batch) do
              m when is_map(m) -> [m]
              _ -> []
            end
          end)

        _ ->
          []
      end
    end

    # ---- variant B/D: GraphQL (B = current+Dataloader, D = preloaded field) ----
    defp variant_gql(query, viewer, subjects, limit) do
      {:ok, result} =
        Absinthe.run(query, Schema,
          variables: %{"first" => limit, "subjects" => subjects},
          context: Schema.context(%{current_user: viewer})
        )

      data = result[:data] || %{}
      conn = data["feedActivities"] || data["feedActivitiesPreloaded"]

      case conn do
        %{"edges" => edges} when is_list(edges) ->
          Enum.map(edges, & &1["node"])

        _ ->
          flunk("GraphQL variant did not return a feed: #{inspect(result, limit: :infinity)}")
      end
    end

    # Count DB queries issued while running `fun` once (Ecto derives the prefix from
    # the repo module: Bonfire.Common.Repo -> [:bonfire, :common, :repo]).
    defp count_queries(fun) do
      counter = :counters.new(1, [])
      handler_id = {__MODULE__, :q, make_ref()}

      :telemetry.attach(
        handler_id,
        [:bonfire, :common, :repo, :query],
        fn _e, _meas, _meta, _cfg -> :counters.add(counter, 1, 1) end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

      :counters.get(counter, 1)
    end

    # Total operation time + Dataloader batch-run count via telemetry. Dataloader runs
    # are the coordination rounds variant D removes by resolving from preloaded structs.
    defp absinthe_breakdown(fun) do
      acc = :atomics.new(3, [])

      events = [
        {[:absinthe, :execute, :operation, :stop], 1},
        {[:dataloader, :source, :batch, :run, :stop], 2}
      ]

      ids =
        for {ev, idx} <- events do
          id = {__MODULE__, ev, make_ref()}

          :telemetry.attach(
            id,
            ev,
            fn _e, meas, _m, _c ->
              :atomics.add(acc, idx, Map.get(meas, :duration, 0))
              if idx == 2, do: :atomics.add(acc, 3, 1)
            end,
            nil
          )

          id
        end

      try do
        fun.()
      after
        Enum.each(ids, &:telemetry.detach/1)
      end

      ms = fn n -> Float.round(System.convert_time_unit(n, :native, :microsecond) / 1000, 1) end

      %{operation_ms: ms.(:atomics.get(acc, 1)), dataloader_count: :atomics.get(acc, 3)}
    end
  end
end
