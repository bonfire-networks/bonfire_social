defmodule Bonfire.Social.Threads.OrphanRescueTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Posts
  alias Bonfire.Social.Threads
  alias Bonfire.Me.Fake

  describe "rescue_orphaned_replies/1" do
    test "adds a stub for a missing parent, placed before its first present descendant" do
      assert [%{id: "a", path: ["thread"], stub: true}, %{id: "b", path: ["thread", "a"]}] =
               Threads.rescue_orphaned_replies([%{id: "b", path: ["thread", "a"]}])
    end

    test "a rescued subtree keeps its reading position among siblings" do
      replies = [
        %{id: "r1", path: ["thread"]},
        %{id: "orphan", path: ["thread", "hidden"]},
        %{id: "r3", path: ["thread"]}
      ]

      assert [
               %{id: "r1"},
               %{id: "hidden", stub: true},
               %{id: "orphan"},
               %{id: "r3"}
             ] = Threads.rescue_orphaned_replies(replies)
    end

    test "adds nothing when all parents are present" do
      replies = [%{id: "a", path: ["thread"]}, %{id: "b", path: ["thread", "a"]}]

      assert Threads.rescue_orphaned_replies(replies) == replies
    end

    test "never stubs the thread root" do
      replies = [%{id: "a", path: ["thread"]}]

      assert Threads.rescue_orphaned_replies(replies) == replies
    end

    test "reconstructs a whole chain of missing ancestors" do
      stubbed = Threads.rescue_orphaned_replies([%{id: "c", path: ["thread", "a", "b"]}])

      assert length(stubbed) == 3
      assert %{path: ["thread", "a"], stub: true} = Enum.find(stubbed, &(&1.id == "b"))
      assert %{path: ["thread"], stub: true} = Enum.find(stubbed, &(&1.id == "a"))
    end

    test "does not stub ancestors of the query root when arranging a branch subtree" do
      # loading deeper replies of comment "b": its own ancestors are absent by design
      replies = [%{id: "c", path: ["thread", "a", "b"]}]

      assert Threads.rescue_orphaned_replies(replies, "b") == replies
    end

    test "adds a single stub shared by orphaned siblings" do
      stubbed =
        Threads.rescue_orphaned_replies([
          %{id: "b", path: ["thread", "a"]},
          %{id: "c", path: ["thread", "a"]}
        ])

      assert length(stubbed) == 3
      assert [%{id: "a", stub: true}] = Enum.filter(stubbed, &(&1[:stub] == true))
    end
  end

  describe "prepare_replies_tree/2 with a boundary-hidden parent" do
    setup do
      alice = Fake.fake_user!("alice")
      bob = Fake.fake_user!("bob")
      charlie = Fake.fake_user!("charlie")

      {:ok, op} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "<p>OP</p>"}},
          boundary: "public"
        )

      # bob's reply is only visible to bob ("mentions" with no mentions grants nobody else)
      {:ok, hidden_reply} =
        Posts.publish(
          current_user: bob,
          post_attrs: %{
            post_content: %{html_body: "<p>hidden parent</p>"},
            reply_to_id: op.id
          },
          boundary: "mentions"
        )

      {:ok, public_child} =
        Posts.publish(
          current_user: bob,
          post_attrs: %{
            post_content: %{html_body: "<p>public child</p>"},
            reply_to_id: hidden_reply.id
          },
          boundary: "public"
        )

      {:ok,
       alice: alice,
       bob: bob,
       charlie: charlie,
       op: op,
       hidden_reply: hidden_reply,
       public_child: public_child}
    end

    test "the orphaned subtree stays in the tree, attached under a stub node", %{
      charlie: charlie,
      op: op,
      hidden_reply: hidden_reply,
      public_child: public_child
    } do
      %{edges: replies} =
        Threads.list_replies(op.id, current_user: charlie, total_replies_count: 2)

      reply_ids = Enum.map(replies, & &1.id)
      assert public_child.id in reply_ids
      refute hidden_reply.id in reply_ids

      tree = Threads.prepare_replies_tree(replies, current_user: charlie)

      assert [{stub, [{child, []}]}] = tree
      assert stub.id == hidden_reply.id
      assert stub[:stub] == true
      assert child.id == public_child.id
    end

    test "load-more of a branch's subtree does not wrap results in ancestor stubs", %{
      bob: bob,
      public_child: public_child
    } do
      # a deeper reply so there is a subtree to load under public_child
      {:ok, deeper} =
        Posts.publish(
          current_user: bob,
          post_attrs: %{
            post_content: %{html_body: "<p>deeper</p>"},
            reply_to_id: public_child.id
          },
          boundary: "public"
        )

      # mirror the load_more_replies handler: query rooted at the branch comment
      %{edges: replies} =
        Threads.list_nested_replies(public_child.id, current_user: bob, max_depth: 10)

      tree = Threads.prepare_replies_tree(replies, thread_id: public_child.id, current_user: bob)

      # exactly the one real reply — no ancestor stubs wrapping it
      assert [{node, []}] = tree
      assert node.id == deeper.id
      refute Map.get(node, :stub) == true
    end

    test "positive control: no stub when the viewer can see the parent", %{
      bob: bob,
      op: op,
      hidden_reply: hidden_reply,
      public_child: public_child
    } do
      %{edges: replies} = Threads.list_replies(op.id, current_user: bob, total_replies_count: 2)

      reply_ids = Enum.map(replies, & &1.id)
      assert hidden_reply.id in reply_ids
      assert public_child.id in reply_ids

      tree = Threads.prepare_replies_tree(replies, current_user: bob)

      assert [{parent, [{child, []}]}] = tree
      assert parent.id == hidden_reply.id
      refute Map.get(parent, :stub) == true
      assert child.id == public_child.id
    end
  end
end
