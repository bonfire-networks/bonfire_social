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

  describe "arrange_replies_tree/2 — cap" do
    test "cap drops subtrees exceeding limit", %{alice: alice, op: op} do
      Process.put([:bonfire, :pagination_hard_max_limit], 2)

      r1 = publish_reply(alice, op.id, 1)
      publish_reply(alice, r1.id, 2)
      publish_reply(alice, r1.id, 3)
      r2 = publish_reply(alice, op.id, 4)
      publish_reply(alice, r2.id, 5)

      replies = Threads.list_nested_replies(op.id, current_user: alice)

      tree = Threads.arrange_replies_tree(replies.edges)

      # cap=2: first subtree (r1 + 2 children = 3 nodes) is oversized but included alone;
      # second subtree dropped
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
