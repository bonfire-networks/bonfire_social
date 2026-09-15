defmodule Bonfire.Social.Feeds.ReplyParentNotificationsTest do
  @moduledoc """
  A reply notifies the author of the post it ANSWERS, and nobody else by virtue of threading.

  Two distinct facts, which a nested reply is what separates:

    * a direct reply notifies the person it replies to, and since `:my` carries notifications it turns up there too, even with no follow between them
    * a reply further down notifies the author of ITS parent (plus any mentions), NOT whoever started the thread

  The second is the one that regresses quietly. `Threads.load_replyable/2` proloads two branches that both end in `created: [creator: …]`, the thread's creator and the parent's own, so with unnamed bindings the parent's creator resolves to the THREAD's, and everything reading `reply_to.created.creator` (`Feeds.reply_and_or_mentions_to_notify/5` and `Feeds.feed_ids_to_publish/4`) notifies the thread originator for every reply in the thread. Nothing else observes the difference until a thread is three deep, which is why this test builds one.
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

  # The regression guard. Paired with the two asserts above so a wholesale failure to notify cannot masquerade as this passing.
  test "a nested reply does NOT notify whoever started the thread", %{alice: alice} do
    refute FeedLoader.feed_contains?(notifications(alice), "carol answers bob",
             current_user: alice
           ),
           "alice started the thread but carol was answering bob, so this is not alice's business"
  end

  test "a direct reply reaches the answered author's :my feed, which carries notifications", %{
    alice: alice
  } do
    %{edges: my_feed} = FeedLoader.feed(:my, current_user: alice, limit: 100)

    assert FeedLoader.feed_contains?(my_feed, "bob answers alice", current_user: alice),
           "`:my` includes notifications, so a reply to alice belongs there with no follow involved"
  end

  test "a nested reply stays out of the thread starter's :my feed", %{alice: alice} do
    %{edges: my_feed} = FeedLoader.feed(:my, current_user: alice, limit: 100)

    refute FeedLoader.feed_contains?(my_feed, "carol answers bob", current_user: alice),
           "alice neither wrote the parent nor follows carol, so nothing puts this in her feed"
  end
end
