defmodule Bonfire.Social.Threads.SortTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Posts
  alias Bonfire.Social.Threads
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Boosts
  alias Bonfire.Me.Fake

  setup do
    alice = Fake.fake_user!("alice")
    bob = Fake.fake_user!("bob")
    carol = Fake.fake_user!("carol")

    {:ok, op} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "<p>OP</p>"}},
        boundary: "public"
      )

    {:ok, alice: alice, bob: bob, carol: carol, op: op}
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

  defp list_and_arrange(op, alice, sort_by) do
    replies = Threads.list_nested_replies(op.id, current_user: alice, sort_by: sort_by)
    Threads.arrange_replies_tree(replies.edges, sort_by: sort_by, sort_order: :desc)
  end

  defp first_branch_id(tree) do
    tree |> List.first() |> elem(0) |> Map.get(:id)
  end

  describe "arrange_replies_tree/2 — sort_by: :reply_count" do
    test "branch with more nested replies ranks first", %{alice: alice, op: op} do
      # r1 published first (lower ID) — default desc sort puts it last without implementation
      r1 = publish_reply(alice, op.id, 1)
      _r2 = publish_reply(alice, op.id, 2)
      # give r1 two sub-replies so it should win on reply_count
      publish_reply(alice, r1.id, 3)
      publish_reply(alice, r1.id, 4)

      tree = list_and_arrange(op, alice, :reply_count)

      assert first_branch_id(tree) == r1.id
    end

    test "branch with no replies ranks last", %{alice: alice, op: op} do
      # r1 published first (lower ID) — default desc sort puts it last without implementation
      r1 = publish_reply(alice, op.id, 1)
      r2 = publish_reply(alice, op.id, 2)
      # r1 has a sub-reply; r2 has none
      publish_reply(alice, r1.id, 3)

      tree = list_and_arrange(op, alice, :reply_count)

      assert first_branch_id(tree) == r1.id
      assert tree |> List.last() |> elem(0) |> Map.get(:id) == r2.id
    end
  end

  describe "arrange_replies_tree/2 — sort_by: :like_count" do
    test "branch with more likes ranks first", %{alice: alice, bob: bob, carol: carol, op: op} do
      # r1 published first (lower ID) — default desc sort puts it last without implementation
      r1 = publish_reply(alice, op.id, 1)
      _r2 = publish_reply(alice, op.id, 2)
      # like only r1 so it should win despite lower ID
      {:ok, _} = Likes.like(bob, r1)
      {:ok, _} = Likes.like(carol, r1)

      tree = list_and_arrange(op, alice, :like_count)

      assert first_branch_id(tree) == r1.id
    end

    test "branch with likes on a nested reply also ranks higher", %{
      alice: alice,
      bob: bob,
      op: op
    } do
      # r1 published first (lower ID)
      r1 = publish_reply(alice, op.id, 1)
      _r2 = publish_reply(alice, op.id, 2)
      child = publish_reply(alice, r1.id, 3)
      # like the child of r1 — r1's branch should still rank higher
      {:ok, _} = Likes.like(bob, child)

      tree = list_and_arrange(op, alice, :like_count)

      assert first_branch_id(tree) == r1.id
    end
  end

  describe "arrange_replies_tree/2 — sort_by: :boost_count" do
    test "branch with more boosts ranks first", %{alice: alice, bob: bob, carol: carol, op: op} do
      # r1 published first (lower ID) — default desc sort puts it last without implementation
      r1 = publish_reply(alice, op.id, 1)
      _r2 = publish_reply(alice, op.id, 2)
      {:ok, _} = Boosts.boost(bob, r1)
      {:ok, _} = Boosts.boost(carol, r1)

      tree = list_and_arrange(op, alice, :boost_count)

      assert first_branch_id(tree) == r1.id
    end
  end

  describe "arrange_replies_tree/2 — sort_by: :popularity_score" do
    test "branch with likes and boosts outranks a branch with only replies", %{
      alice: alice,
      bob: bob,
      carol: carol,
      op: op
    } do
      # r1 published first (lower ID): boosted by bob and carol — should win despite lower ID
      # score: 2 boosts * weight_boosts(2) + 1 like * weight_likes(1) = 5
      r1 = publish_reply(alice, op.id, 1)
      {:ok, _} = Boosts.boost(bob, r1)
      {:ok, _} = Boosts.boost(carol, r1)
      {:ok, _} = Likes.like(bob, r1)

      # r2 published after (higher ID): 1 sub-reply but no reactions
      # score: 1 reply * weight_replies(3) = 3
      r2 = publish_reply(alice, op.id, 2)
      publish_reply(alice, r2.id, 3)

      tree = list_and_arrange(op, alice, :popularity_score)

      assert first_branch_id(tree) == r1.id
    end
  end
end
