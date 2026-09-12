defmodule Bonfire.Social.Threads.ListRepliesPaginationTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Posts
  alias Bonfire.Social.Threads
  alias Bonfire.Me.Fake

  setup do
    alice = Fake.fake_user!("alice")

    {:ok, op} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "<p>OP</p>"}},
        boundary: "public"
      )

    on_exit(fn ->
      Process.put([:bonfire, :thread_pagination_hard_limit], nil)
      Process.put([:bonfire, :thread_default_root_reply_limit], nil)
      Process.put([:bonfire, :pagination_hard_max_limit], nil)
      Process.put([:bonfire, :default_pagination_limit], nil)
    end)

    {:ok, alice: alice, op: op}
  end

  defp publish_reply(user, reply_to_id, n \\ 1) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{
          post_content: %{html_body: "<p>reply #{n}</p>"},
          reply_to_id: reply_to_id
        },
        boundary: "public"
      )

    post
  end

  describe "list_replies/2 — flat mode" do
    test "paginates flat replies with limit", %{alice: alice, op: op} do
      Process.put([:bonfire, :default_pagination_limit], 2)
      Process.put([:bonfire, :pagination_hard_max_limit], 2)

      for n <- 1..4, do: publish_reply(alice, op.id, n)

      result = Threads.list_replies(op.id, thread_mode: :flat, current_user: alice)

      assert length(result.edges) == 2
      assert not is_nil(result.page_info.end_cursor)
    end

    test "no load more when replies fit within limit", %{alice: alice, op: op} do
      Process.put([:bonfire, :default_pagination_limit], 10)
      Process.put([:bonfire, :pagination_hard_max_limit], 10)

      for n <- 1..3, do: publish_reply(alice, op.id, n)

      result = Threads.list_replies(op.id, thread_mode: :flat, current_user: alice)

      assert length(result.edges) == 3
      assert is_nil(result.page_info.end_cursor)
    end
  end

  describe "list_replies/2 — nested two-step path" do
    test "a deep permalink loads all readable ancestors outside the root page", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      Process.put([:bonfire, :thread_default_root_reply_limit], 2)

      chain = Enum.scan(1..6, op, fn n, parent -> publish_reply(alice, parent.id, n) end)
      target = List.last(chain)

      result = Threads.list_replies(op.id,
        current_user: alice,
        total_replies_count: 6,
        max_depth: 3,
        include_path_ids: Threads.thread_ancestors_path(target.id)
      )

      assert Enum.all?(chain, fn reply -> Enum.any?(result.edges, &(&1.id == reply.id)) end)
      assert length(result.edges) == 6
      assert Enum.all?(Threads.rescue_orphaned_replies(result.edges, op.id), &(Map.get(&1, :stub) != true))
    end

    test "nested pages resolve readable ancestors without changing continuation cursors", %{alice: alice, op: op} do
      parent = publish_reply(alice, op.id)
      child = publish_reply(alice, parent.id)

      result = Threads.list_nested_replies(op.id, current_user: alice, limit: 1, sort_order: :desc)

      assert Enum.sort(Enum.map(result.edges, & &1.id)) == Enum.sort([parent.id, child.id])
      assert result.page_info.end_cursor
    end

    test "resolved ancestors receive the same default content preloads as replies", %{alice: alice, op: op} do
      parent = publish_reply(alice, op.id, 1)
      child = publish_reply(alice, parent.id, 2)

      result = Threads.list_nested_replies(op.id, current_user: alice, limit: 1, sort_order: :desc)

      for post <- [parent, child] do
        reply = Enum.find(result.edges, &(&1.id == post.id))
        assert reply.activity.object.post_content.html_body == post.post_content.html_body
      end
    end

    test "permalink ancestors do not consume or change branch continuation pages", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_default_root_reply_limit], 1)
      roots = for n <- 1..3, do: publish_reply(alice, op.id, n)
      target = publish_reply(alice, hd(roots).id, 4)
      opts = [current_user: alice, total_replies_count: 100, sort_order: :desc]
      permalink_opts = Keyword.put(opts, :include_path_ids, Threads.thread_ancestors_path(target.id))

      {branch_ids, _cursor} =
        Enum.reduce(1..3, {[], nil}, fn page_number, {ids, cursor} ->
          page = Threads.list_replies(op.id, Keyword.put(opts, :after, cursor))
          permalink_page = Threads.list_replies(op.id, Keyword.put(permalink_opts, :after, cursor))
          assert permalink_page.page_info == page.page_info
          assert Enum.any?(permalink_page.edges, &(&1.id == target.id))
          page_roots = Enum.filter(page.edges, &(length(&1.path) == 1))
          assert length(page_roots) == 1
          assert (page.page_info.end_cursor == nil) == (page_number == 3)
          {ids ++ Enum.map(page_roots, & &1.id), page.page_info.end_cursor}
        end)

      assert Enum.sort(branch_ids) == Enum.sort(Enum.map(roots, & &1.id))
    end

    test "when total_replies exceeds hard_limit, uses root pagination", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      Process.put([:bonfire, :thread_default_root_reply_limit], 2)

      for n <- 1..4, do: publish_reply(alice, op.id, n)

      result = Threads.list_replies(op.id, current_user: alice, total_replies_count: 4)

      assert not is_nil(result.page_info.end_cursor)
      # only the first page of root replies + their descendants
      assert length(result.edges) <= 4
    end

    test "descendants of root replies are included in the page", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 1)
      Process.put([:bonfire, :thread_default_root_reply_limit], 1)

      # publish r2 first so it's older; r1 (published last) comes first on descending sort
      _r2 = publish_reply(alice, op.id, 3)
      r1 = publish_reply(alice, op.id, 1)
      _child = publish_reply(alice, r1.id, 2)

      result = Threads.list_replies(op.id, current_user: alice, total_replies_count: 3)

      # first page = 1 root reply + its child = 2 nodes; r2 on next page
      assert not is_nil(result.page_info.end_cursor)
      assert length(result.edges) == 2
    end

    test "all replies returned when total_replies fits in one root page", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      Process.put([:bonfire, :thread_default_root_reply_limit], 10)

      for n <- 1..3, do: publish_reply(alice, op.id, n)

      result = Threads.list_replies(op.id, current_user: alice, total_replies_count: 3)

      # 3 <= hard_limit(2) is FALSE, but root_limit(10) >= 3, so all fit on first root page
      assert length(result.edges) == 3
      assert is_nil(result.page_info.end_cursor)
    end
  end

  describe "list_replies/2 — known_small skip" do
    test "skips two-step when total_replies <= hard_limit", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 10)
      Process.put([:bonfire, :thread_default_root_reply_limit], 1)

      for n <- 1..3, do: publish_reply(alice, op.id, n)

      # total_replies(3) <= hard_limit(10) → known_small → single query loads all
      result = Threads.list_replies(op.id, current_user: alice, total_replies_count: 3)

      assert length(result.edges) == 3
    end

    test "caches thread as small after two-step confirms no next page", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      Process.put([:bonfire, :thread_default_root_reply_limit], 10)

      for n <- 1..2, do: publish_reply(alice, op.id, n)

      cache_key = "thread_small:#{op.id}"
      refute Bonfire.Common.Cache.get!(cache_key) == true

      # first call: 2 replies, total > hard_limit(2) is false... actually 2 == 2 <= 2 so known_small
      # Let's use nil total so we force two-step
      _result = Threads.list_replies(op.id, current_user: alice, total_replies_count: nil)

      # two-step ran, no next page → cached as small
      assert Bonfire.Common.Cache.get!(cache_key) == true
    end

    test "a terminal continuation page does not cache the whole thread as small", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_default_root_reply_limit], 1)
      for n <- 1..2, do: publish_reply(alice, op.id, n)
      opts = [current_user: alice]
      first = Threads.list_replies(op.id, opts)
      assert first.page_info.end_cursor
      last = Threads.list_replies(op.id, opts ++ [after: first.page_info.end_cursor])
      assert last.page_info.end_cursor == nil
      refute Bonfire.Common.Cache.get!("thread_small:#{op.id}") == true
    end

    test "a branch exceeding the reply limit is not cached as small", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      parent = publish_reply(alice, op.id)
      for n <- 1..3, do: publish_reply(alice, parent.id, n)
      result = Threads.list_replies(op.id, current_user: alice)
      assert length(result.edges) == 4
      assert result.page_info.end_cursor == nil
      refute Bonfire.Common.Cache.get!("thread_small:#{op.id}") == true
    end

    test "a known large count takes precedence over an older small cache entry", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      Process.put([:bonfire, :thread_default_root_reply_limit], 1)
      for n <- 1..3, do: publish_reply(alice, op.id, n)
      Bonfire.Common.Cache.put("thread_small:#{op.id}", true)
      result = Threads.list_replies(op.id, current_user: alice, total_replies_count: 3)
      assert length(result.edges) == 1
      assert result.page_info.end_cursor
    end

    test "uses single query on second call when cached as small", %{alice: alice, op: op} do
      Process.put([:bonfire, :thread_pagination_hard_limit], 2)
      Process.put([:bonfire, :thread_default_root_reply_limit], 10)

      for n <- 1..2, do: publish_reply(alice, op.id, n)

      cache_key = "thread_small:#{op.id}"

      # first call forces two-step (total unknown)
      Threads.list_replies(op.id, current_user: alice, total_replies_count: nil)
      assert Bonfire.Common.Cache.get!(cache_key) == true

      # second call: cached_small=true → takes known_small branch
      result = Threads.list_replies(op.id, current_user: alice, total_replies_count: nil)
      assert length(result.edges) == 2
    end
  end

  describe "arrange_replies_tree/2 — paginated replies" do
    test "a bounded reply page remains small after tree arrangement", %{alice: alice, op: op} do
      Process.put([:bonfire, :pagination_hard_max_limit], 2)

      r1 = publish_reply(alice, op.id, 1)
      publish_reply(alice, r1.id, 2)
      publish_reply(alice, r1.id, 3)
      r2 = publish_reply(alice, op.id, 4)
      publish_reply(alice, r2.id, 5)

      replies = Threads.list_nested_replies(op.id, current_user: alice)

      tree = Threads.arrange_replies_tree(replies.edges)

      # The reply query is limited; arrangement also retains any loaded ancestors.
      node_count = count_tree(tree)
      assert node_count <= 3
    end

    defp count_tree(nodes) when is_list(nodes) do
      Enum.reduce(nodes, 0, fn {_node, children}, acc ->
        acc + 1 + count_tree(children)
      end)
    end
  end
end
