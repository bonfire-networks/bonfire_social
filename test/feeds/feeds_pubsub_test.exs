defmodule Bonfire.Social.FeedsPubTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils
  alias Bonfire.Common.PubSub

  import Bonfire.Files.Simulation
  # import Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Posts
  alias Bonfire.Messages
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]
  import Tesla.Mock
  # use Mneme

  test "basic PubSub broadcast mechanism works" do
    user = fake_user!("pubsub_local")
    feed_id = "local_feed_test"
    :ok = PubSub.subscribe(feed_id, current_user: user)

    post_content = "PubSub local feed test"

    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: post_content}},
        boundary: "public"
      )

    activity = post.activity

    Bonfire.Social.LivePush.push_activity(feed_id, activity)

    assert_receive {
      {Bonfire.Social.Feeds, :new_activity},
      [feed_ids: ^feed_id, activity: ^activity]
    }

    # sanity check
    refute_received {
      {Bonfire.Social.Feeds, :new_activity},
      [feed_ids: "something_else", activity: "123"]
    }
  end

  test "PubSub broadcasts new activity to local feed" do
    user = fake_user!("pubsub_local")
    feed_id = Feeds.named_feed_id(:local)
    :ok = PubSub.subscribe(feed_id, current_user: user)

    post_content = "PubSub local feed test"

    {:ok, %{id: post_id} = post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: post_content}},
        boundary: "public"
      )

    activity = post.activity

    # shouldn't be called manually since the LivePush Act should handle it as part of the posting Epic
    # Bonfire.Social.LivePush.push_activity(feed_id, activity)

    assert_receive {
      {Bonfire.Social.Feeds, :new_activity},
      [
        feed_ids: [_, "0AND0MSTRANGERS0FF1NTERNET", "3SERSFR0MY0VR10CA11NSTANCE"],
        activity: %{id: ^post_id}
      ]
    }
  end

  test "PubSub broadcasts new activity to user profile feed" do
    user = fake_user!("pubsub_user")

    feed_id = Bonfire.Social.Feeds.feed_ids(:outbox, user)
    :ok = PubSub.subscribe(feed_id, current_user: user)

    post_content = "PubSub user feed test"

    {:ok, %{id: post_id} = post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: post_content}},
        boundary: "public"
      )

    activity = post.activity

    # shouldn't be called manually since the LivePush Act should handle it as part of the posting Epic
    # Bonfire.Social.LivePush.push_activity(feed_id, activity)

    assert_receive {
      {Bonfire.Social.Feeds, :new_activity},
      [
        feed_ids: [_, "0AND0MSTRANGERS0FF1NTERNET", "3SERSFR0MY0VR10CA11NSTANCE"],
        activity: %{id: ^post_id}
      ]
    }
  end

  test "PubSub broadcasts new reply activity to thread" do
    user = fake_user!("pubsub_thread")
    # Create an original post (the thread root)
    {:ok, %{id: thread_id} = post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "Thread root"}},
        boundary: "public"
      )

    activity = post.activity

    :ok = PubSub.subscribe(thread_id, current_user: user)

    # Create a reply to the original post
    reply_content = "This is a reply in the thread"

    {:ok, %{id: reply_id} = reply_post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{
          post_content: %{html_body: reply_content},
          reply_to: thread_id
        },
        boundary: "public"
      )

    reply_activity = reply_post.activity

    # shouldn't be called manually since the LivePush Act should handle it as part of the posting Epic
    # Bonfire.Social.LivePush.push_activity(thread_id, reply_activity)

    assert_receive {
      {Bonfire.Social.Threads.LiveHandler, :new_reply},
      {^thread_id, %{id: ^reply_id}}
    }
  end

  test "PubSub broadcasts new message activity to inbox feed" do
    sender = fake_user!("pubsub_inbox_sender")
    recipient = fake_user!("pubsub_inbox_recipient")

    inbox_feed_id = Bonfire.Social.Feeds.my_feed_id(:inbox, recipient)
    :ok = PubSub.subscribe(inbox_feed_id, current_user: recipient)

    message_content = "Hello from PubSub inbox test!"

    {:ok, %{activity: activity}} =
      Bonfire.Messages.send(
        sender,
        %{post_content: %{html_body: message_content}},
        [recipient.id]
      )

    assert_receive {:new_message, _}
  end
end
