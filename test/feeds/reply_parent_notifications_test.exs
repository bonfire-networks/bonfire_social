defmodule Bonfire.Social.Feeds.ReplyParentNotificationsTest do
  @moduledoc """
  A reply notifies whoever wrote a post above it in the thread, because writing a post enables notifications of the replies below it (`Bonfire.Notify.Bells.enable_thread_notifications_changeset/3`), which each of them can turn off for that post.

  Distinct facts, which a nested reply is what separates:

    * a direct reply notifies the person it replies to, and since `:my` carries notifications it turns up there too, even with no follow between them
    * a reply further down notifies the author of its parent, and whoever started the thread too
    * someone who turned notifications off for their post isn't notified of the replies below it, however deep, while the others above still are

  The thread is three deep because nothing tells "the parent's author" and "the thread's author" apart before that.
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Posts
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Me.Fake

  setup do
    # `alice` starts a thread, `bob` answers her, `carol` answers bob. Nobody follows anybody, so anything reaching a `:my` feed got there by notification rather than subscription.
    alice = Fake.fake_user!()
    bob = Fake.fake_user!()
    carol = Fake.fake_user!()

    {:ok, root} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "alice starts a thread"}},
        boundary: "public"
      )

    {:ok, direct_reply} =
      Posts.publish(
        current_user: bob,
        post_attrs: %{
          post_content: %{html_body: "bob answers alice"},
          reply_to_id: root.id
        },
        boundary: "public"
      )

    {:ok, nested_reply} =
      Posts.publish(
        current_user: carol,
        post_attrs: %{
          post_content: %{html_body: "carol answers bob"},
          reply_to_id: direct_reply.id
        },
        boundary: "public"
      )

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      root: root,
      direct_reply: direct_reply,
      nested_reply: nested_reply
    }
  end

  defp notifications(user) do
    %{edges: edges} = FeedLoader.feed(:notifications, current_user: user, limit: 100)
    edges
  end

  test "a direct reply notifies the author it answers", %{alice: alice} do
    assert FeedLoader.feed_contains?(notifications(alice), "bob answers alice",
             current_user: alice
           ),
           "answering someone's post is the notification case, whether or not they follow you"
  end

  test "a nested reply notifies the author of its own parent", %{bob: bob} do
    assert FeedLoader.feed_contains?(notifications(bob), "carol answers bob", current_user: bob),
           "carol answered bob, so bob is the one with something to read"
  end

  test "a nested reply notifies whoever started the thread", %{alice: alice} do
    assert FeedLoader.feed_contains?(notifications(alice), "carol answers bob",
             current_user: alice
           ),
           "carol's reply is below alice's post, which enabled notifications of its replies for alice"
  end

  # was "a nested reply does NOT notify whoever started the thread", from when a reply only notified the author of its parent; that's now what turning a post's notifications off does
  test "with her post's notifications off, a nested reply doesn't notify whoever started the thread",
       %{bob: bob, carol: carol} do
    {alice, root} = thread_with_notifications_off()
    {direct_reply, nested_reply} = replies_below(root, bob, carol, "quiet")

    # the positive first: bob, whose notifications are on, still hears about carol
    assert FeedLoader.feed_contains?(notifications(bob), nested_reply, current_user: bob)

    refute FeedLoader.feed_contains?(notifications(alice), nested_reply, current_user: alice),
           "alice turned off notifications for her post, which covers the replies below it"

    refute FeedLoader.feed_contains?(notifications(alice), direct_reply, current_user: alice),
           "and the direct replies to it"
  end

  test "a direct reply reaches the answered author's :my feed, which carries notifications", %{
    alice: alice
  } do
    %{edges: my_feed} = FeedLoader.feed(:my, current_user: alice, limit: 100)

    assert FeedLoader.feed_contains?(my_feed, "bob answers alice", current_user: alice),
           "`:my` includes notifications, so a reply to alice belongs there with no follow involved"
  end

  # was "a nested reply stays out of the thread starter's :my feed", likewise
  test "with her post's notifications off, a nested reply stays out of the thread starter's :my feed",
       %{bob: bob, carol: carol} do
    {alice, root} = thread_with_notifications_off()
    {_direct_reply, nested_reply} = replies_below(root, bob, carol, "quiet")

    %{edges: my_feed} = FeedLoader.feed(:my, current_user: alice, limit: 100)

    refute FeedLoader.feed_contains?(my_feed, nested_reply, current_user: alice),
           "alice neither follows carol nor gets notifications for that post, so nothing puts this in her feed"
  end

  # a thread whose starter turned off notifications for her post straight away
  defp thread_with_notifications_off do
    alice = Fake.fake_user!()

    {:ok, root} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "alice starts a quiet thread"}},
        boundary: "public"
      )

    Bonfire.Notify.Bells.disable(alice, root)

    {alice, root}
  end

  defp replies_below(root, bob, carol, label) do
    {:ok, direct_reply} =
      Posts.publish(
        current_user: bob,
        post_attrs: %{
          post_content: %{html_body: "bob answers the #{label} thread"},
          reply_to_id: root.id
        },
        boundary: "public"
      )

    {:ok, nested_reply} =
      Posts.publish(
        current_user: carol,
        post_attrs: %{
          post_content: %{html_body: "carol answers bob in the #{label} thread"},
          reply_to_id: direct_reply.id
        },
        boundary: "public"
      )

    {direct_reply, nested_reply}
  end
end
