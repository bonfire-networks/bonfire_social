defmodule Bonfire.Social.SeenTest do
  use Bonfire.Social.DataCase

  alias Bonfire.Social.Seen
  alias Bonfire.Posts

  alias Bonfire.Me.Fake

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
  end
end
