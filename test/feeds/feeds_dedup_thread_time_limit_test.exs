defmodule Bonfire.Social.FeedsDedupThreadTimeLimitTest do
  @moduledoc """
  Regression tests for `dedup_by_thread` feeds (used by the group "Discussions" tab via the `:recent_discussions` preset):

  1. the time window must apply to a thread's LATEST activity (matching the latest-reply sort), not to the thread root's own timestamp — an old thread with fresh replies must stay visible

  2. a thread whose root was never published to the queried feed (e.g. it predates the group) must still appear, represented by its earliest entry in that feed — and its window/ranking must still follow the thread's latest reply, not that earliest entry's own age

  3. an entry that is itself recent (e.g. a fresh boost of an old post) counts as thread activity for the window

  4. the query picks a page of thread candidates in a deferred inner query with a `LIMIT`, so boundaries and preloads only run on those rows and Postgres plans for one page whatever the size of the instance; each candidate's latest reply comes from a per-thread lookup
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds

  defp fake_post_days_ago!(user, days, attrs) do
    fake_post!(
      user,
      "public",
      Map.put(attrs, :id, DatesTimes.past(days, :day) |> DatesTimes.generate_ulid())
    )
  end

  describe "dedup_by_thread applies the time window to the thread's latest activity" do
    setup do
      %{user: fake_user!("thread window viewer"), author: fake_user!("thread window author")}
    end

    test "keeps a thread started before the window when its latest reply is within it", %{
      user: user,
      author: author
    } do
      old_root =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old active thread", html_body: "root from ten days ago"}
        })

      _fresh_reply =
        fake_post!(author, "public", %{
          post_content: %{html_body: "fresh reply to the old thread"},
          reply_to_id: old_root.id
        })

      feed =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      assert FeedLoader.feed_contains?(feed, old_root, current_user: user)
    end

    test "hides a thread whose latest activity is older than the window", %{
      user: user,
      author: author
    } do
      old_root =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old stale thread", html_body: "root from ten days ago"}
        })

      _old_reply =
        fake_post_days_ago!(author, 9, %{
          post_content: %{html_body: "reply from nine days ago"},
          reply_to_id: old_root.id
        })

      feed =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      refute FeedLoader.feed_contains?(feed, old_root, current_user: user)
    end

    test "keeps a fresh thread with no replies", %{user: user, author: author} do
      fresh_root =
        fake_post!(author, "public", %{
          post_content: %{name: "fresh thread", html_body: "root from just now"}
        })

      feed =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      assert FeedLoader.feed_contains?(feed, fresh_root, current_user: user)
    end

    test "ranks an old thread with the most recent reply above fresher-started threads", %{
      user: user,
      author: author
    } do
      fresh_root =
        fake_post!(author, "public", %{
          post_content: %{name: "fresh but quiet thread", html_body: "recent root, no replies"}
        })

      old_root =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old busy thread", html_body: "root from ten days ago"}
        })

      # created after fresh_root, so this thread has the most recent activity overall
      _fresh_reply =
        fake_post!(author, "public", %{
          post_content: %{html_body: "newest reply overall"},
          reply_to_id: old_root.id
        })

      %{edges: edges} =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      ids = Enum.map(edges, &e(&1, :activity, :object_id, nil))

      old_pos = Enum.find_index(ids, &(&1 == old_root.id))
      fresh_pos = Enum.find_index(ids, &(&1 == fresh_root.id))

      assert old_pos != nil, "old thread with fresh reply should be in the feed"
      assert fresh_pos != nil, "fresh thread should be in the feed"

      assert old_pos < fresh_pos,
             "the old thread (latest activity) should rank above the fresher-started thread"
    end
  end

  describe "dedup_by_thread when the thread root is not in the queried feed" do
    setup do
      %{
        user: fake_user!("rootless viewer"),
        author: fake_user!("rootless author"),
        replier: fake_user!("rootless replier")
      }
    end

    test "represents the thread by its earliest entry instead of hiding it", %{
      user: user,
      author: author,
      replier: replier
    } do
      root =
        fake_post!(author, "public", %{
          post_content: %{name: "thread rooted elsewhere", html_body: "root not in this feed"}
        })

      reply1 =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "first reply in this feed"},
          reply_to_id: root.id
        })

      reply2 =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "second reply in this feed"},
          reply_to_id: root.id
        })

      # the replier's outbox contains their replies but never the root's own activity
      # (using the :recent_discussions preset + feed_ids, same as the group Discussions tab)
      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, replier)]},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, reply1, current_user: user),
             "the thread should appear via its earliest entry in the feed"

      refute FeedLoader.feed_contains?(feed, reply2, current_user: user),
             "the thread should only appear once"

      refute FeedLoader.feed_contains?(feed, root, current_user: user)
    end

    test "windows a rootless thread by its latest reply, not by its earliest entry's age", %{
      user: user,
      author: author,
      replier: replier
    } do
      root =
        fake_post_days_ago!(author, 15, %{
          post_content: %{
            name: "old thread rooted elsewhere",
            html_body: "old root not in this feed"
          }
        })

      old_reply =
        fake_post_days_ago!(replier, 10, %{
          post_content: %{html_body: "old first reply in this feed"},
          reply_to_id: root.id
        })

      fresh_reply =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "fresh reply in this feed"},
          reply_to_id: root.id
        })

      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, replier)], time_limit: 7},
          current_user: user
        )

      # the representative entry (the old first reply) predates the window, but the thread's latest reply is fresh
      # the message lists what the feed returned, so a failure shows whether the entry was missing, replaced or on another page
      assert FeedLoader.feed_contains?(feed, old_reply, current_user: user),
             "an active rootless thread should stay visible even when its earliest in-feed entry is older than the window. Expected root=#{root.id} old_reply=#{old_reply.id} fresh_reply=#{fresh_reply.id}, got: " <>
               inspect(
                 case feed do
                   %{edges: edges, page_info: page_info} ->
                     %{
                       rows:
                         Enum.map(
                           edges,
                           &{e(&1, :activity, :id, nil), e(&1, :activity, :object_id, nil)}
                         ),
                       page_info: page_info
                     }

                   other ->
                     other
                 end
               )
    end

    test "still prefers the root's own entry when it is in the feed", %{
      user: user,
      author: author
    } do
      root =
        fake_post!(author, "public", %{
          post_content: %{name: "self-replied thread", html_body: "root in this feed"}
        })

      reply =
        fake_post!(author, "public", %{
          post_content: %{html_body: "author's own reply"},
          reply_to_id: root.id
        })

      # the author's outbox contains both the root and the reply
      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, author)]},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, root, current_user: user)

      refute FeedLoader.feed_contains?(feed, reply, current_user: user),
             "the thread should be represented by its root, not also by the reply"
    end
  end

  describe "dedup_by_thread counts a recent entry itself as thread activity" do
    test "shows a fresh boost of an old unreplied post within the window" do
      user = fake_user!("boost window viewer")
      author = fake_user!("boost window author")
      booster = fake_user!("boost window booster")

      old_post =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old unreplied post", html_body: "posted ten days ago"}
        })

      {:ok, _boost} = Bonfire.Social.Boosts.boost(booster, old_post)

      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, booster)], time_limit: 7},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, old_post, current_user: user),
             "a fresh boost should count as recent thread activity even though the boosted post is older than the window"
    end
  end

  describe "dedup_by_thread pagination" do
    test "pages in latest-activity order when an old thread has the newest reply" do
      user = fake_user!("thread paging viewer")
      author = fake_user!("thread paging author")
      replier = fake_user!("thread paging replier")

      thread_a =
        fake_post_days_ago!(author, 3, %{
          post_content: %{name: "thread A", html_body: "oldest root, newest reply"}
        })

      thread_b =
        fake_post_days_ago!(author, 2, %{
          post_content: %{name: "thread B", html_body: "middle root, no replies"}
        })

      thread_c =
        fake_post_days_ago!(author, 1, %{
          post_content: %{name: "thread C", html_body: "newest root, no replies"}
        })

      # by the replier, so the author's outbox only holds the three roots
      _reply_to_a =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "newest reply overall"},
          reply_to_id: thread_a.id
        })

      # one thread per page, so every page boundary needs a correct cursor
      pages =
        Stream.unfold({:first, 0}, fn
          {nil, _} ->
            nil

          {_, 5} ->
            nil

          {cursor, n} ->
            paginate = if cursor == :first, do: [limit: 1], else: [limit: 1, after: cursor]

            %{edges: edges, page_info: page_info} =
              FeedLoader.feed(
                :recent_discussions,
                %{feed_ids: [Feeds.feed_id(:outbox, author)], time_limit: 0},
                current_user: user,
                paginate: paginate
              )

            {Enum.map(edges, &e(&1, :activity, :object_id, nil)), {page_info.end_cursor, n + 1}}
        end)
        |> Enum.to_list()

      assert List.flatten(pages) == [thread_a.id, thread_c.id, thread_b.id],
             "expected pages [A], [C], [B] (A=#{thread_a.id} B=#{thread_b.id} C=#{thread_c.id}), got: #{inspect(pages)}"
    end
  end

  describe "dedup_by_thread query shape" do
    test "limits thread candidates in a deferred inner query before boundaries and preloads" do
      user = fake_user!("deferred dedup viewer")
      author = fake_user!("deferred dedup author")

      # same call as the group Discussions tab
      query =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, author)]},
          current_user: user,
          return: :query
        )

      assert %Ecto.Query{} = query

      deferred_join = Enum.find(query.joins, &(&1.as == :deferred_join_subquery))
      assert deferred_join, "the thread-deduped feed should use a deferred join"

      # Ecto stores a joined subquery as a query selecting from it
      assert %Ecto.Query{from: %{source: %Ecto.SubQuery{query: %Ecto.Query{limit: %{}}}}} =
               deferred_join.source
    end

    test "looks up each candidate thread's latest reply instead of aggregating every thread" do
      user = fake_user!("lateral dedup viewer")
      author = fake_user!("lateral dedup author")

      query =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, author)], time_limit: 7},
          current_user: user,
          return: :query
        )

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Bonfire.Common.Repo, query)

      refute sql =~ ~r/GROUP BY \w+\."thread_id"/,
             "the latest reply should not be aggregated over every thread on the instance"

      assert sql =~ "LATERAL"
    end
  end
end
