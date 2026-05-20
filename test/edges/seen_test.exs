defmodule Bonfire.Social.SeenTest do
  use Bonfire.Social.DataCase

  alias Bonfire.Social.Seen
  alias Bonfire.Posts

  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]

  describe "mark_seen with user" do
    test "can mark something as seen using user" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _seen} = Seen.mark_seen(alice, post)
      assert true == Seen.seen?(alice, post)
    end

    test "can check if something is not seen" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert false == Seen.seen?(alice, post)
    end

    test "can mark something as unseen using user" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _seen} = Seen.mark_seen(alice, post)
      Seen.mark_unseen(alice, post)
      assert false == Seen.seen?(alice, post)
    end
  end

  describe "mark_seen with account" do
    test "can mark something as seen using account directly" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _seen} = Seen.mark_seen(account, post)
      assert true == Seen.seen?(account, post)
    end

    test "can mark something as unseen using account directly" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _seen} = Seen.mark_seen(account, post)
      Seen.mark_unseen(account, post)
      assert false == Seen.seen?(account, post)
    end
  end

  describe "account-based tracking behavior" do
    test "seen status is shared across users of the same account" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)
      bob = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      # Mark as seen with alice
      assert {:ok, _seen} = Seen.mark_seen(alice, post)

      # Should also be seen for bob (same account)
      assert true == Seen.seen?(bob, post)

      # And also seen when checking with account directly
      assert true == Seen.seen?(account, post)
    end

    test "seen status is separate for different accounts" do
      account1 = Fake.fake_account!()
      alice = Fake.fake_user!(account1)

      account2 = Fake.fake_account!()
      bob = Fake.fake_user!(account2)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      # Mark as seen with alice (account1)
      assert {:ok, _seen} = Seen.mark_seen(alice, post)

      # Should be seen for alice and her account
      assert true == Seen.seen?(alice, post)
      assert true == Seen.seen?(account1, post)

      # But NOT seen for bob (different account)
      assert false == Seen.seen?(bob, post)
      assert false == Seen.seen?(account2, post)
    end

    test "marking unseen with one user unmarks for all users of same account" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)
      bob = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      # Mark as seen with alice
      assert {:ok, _seen} = Seen.mark_seen(alice, post)
      assert true == Seen.seen?(bob, post)

      # Mark as unseen with bob
      Seen.mark_unseen(bob, post)

      # Should be unseen for both alice and bob
      assert false == Seen.seen?(alice, post)
      assert false == Seen.seen?(bob, post)
      assert false == Seen.seen?(account, post)
    end
  end

  describe "mark_seen with lists" do
    test "can mark multiple objects as seen" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      assert {:ok, post1} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, post2} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert 2 = Seen.mark_seen(alice, [post1, post2])
      assert true == Seen.seen?(alice, post1)
      assert true == Seen.seen?(alice, post2)
    end

    test "marking an empty list is a no-op and returns 0" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)
      assert 0 = Seen.mark_seen(alice, [])
    end

    test "marking the same list twice is idempotent (no constraint error)" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      posts = for _ <- 1..3, do: fake_post!(alice, "public")

      assert 3 = Seen.mark_seen(alice, posts)
      assert Enum.all?(posts, &Seen.seen?(alice, &1))

      assert 0 = Seen.mark_seen(alice, posts)
      assert Enum.all?(posts, &Seen.seen?(alice, &1))
    end

    test "mixed already-seen and unseen returns the count of newly-marked items" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)

      [post1, post2, post3] = for _ <- 1..3, do: fake_post!(alice, "public")

      assert {:ok, _} = Seen.mark_seen(alice, post1)

      assert 2 = Seen.mark_seen(alice, [post1, post2, post3])
      assert Seen.seen?(alice, post1)
      assert Seen.seen?(alice, post2)
      assert Seen.seen?(alice, post3)
    end

    test "list of bare id maps (the FeedActivities.mark_all_seen shape) is marked seen" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)
      post = fake_post!(alice, "public")

      assert 1 = Seen.mark_seen(alice, [%{id: post.id}])
      assert Seen.seen?(alice, post)
    end

    test "bulk insert does not leave orphan Pointer rows for the inserted Seen ids" do
      import Ecto.Query
      alias Bonfire.Data.Edges.Edge

      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)
      posts = for _ <- 1..4, do: fake_post!(alice, "public")

      assert 4 = Seen.mark_seen(alice, posts)

      seen_table_id = Bonfire.Common.Types.table_id(Bonfire.Data.Social.Seen)
      account_id = account.id
      object_ids = Enum.map(posts, & &1.id)

      edge_count =
        Bonfire.Common.Repo.aggregate(
          from(e in Edge,
            where:
              e.table_id == ^seen_table_id and e.subject_id == ^account_id and
                e.object_id in ^object_ids
          ),
          :count,
          :id
        )

      assert edge_count == 4

      orphan_edges =
        Bonfire.Common.Repo.all(
          from(e in Edge,
            left_join: p in Needle.Pointer,
            on: p.id == e.id,
            where:
              e.table_id == ^seen_table_id and e.subject_id == ^account_id and
                e.object_id in ^object_ids and is_nil(p.id),
            select: e.id
          )
        )

      assert orphan_edges == []
    end
  end

  describe "mark_seen performance" do
    @tag :benchmark
    test "marking 50 objects is fast (smoke check)" do
      account = Fake.fake_account!()
      alice = Fake.fake_user!(account)
      posts = for _ <- 1..50, do: fake_post!(alice, "public")

      {time_us, count} = :timer.tc(fn -> Seen.mark_seen(alice, posts) end)

      assert count == 50

      assert time_us < 1_000_000,
             "expected mark_seen of 50 items under 1s, took #{time_us / 1000} ms"
    end
  end
end
