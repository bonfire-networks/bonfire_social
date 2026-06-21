defmodule Bonfire.Social.FeedsSubscriptionTopicsTest do
  @moduledoc "Topic resolution for the `feedActivity` GraphQL subscription (graphql-ws)."
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  alias Bonfire.Social.Feeds

  describe "subscription_topics/2 thread authorization" do
    test "the creator can subscribe to their own thread" do
      alice = fake_user!()
      post = fake_post!(alice, "public", %{post_content: %{html_body: "hello"}})
      assert Feeds.subscription_topics(%{thread_id: post.id}, alice) == [post.id]
    end

    test "anyone can subscribe to a public thread" do
      alice = fake_user!()
      bob = fake_user!()
      post = fake_post!(alice, "public", %{post_content: %{html_body: "hello"}})
      assert Feeds.subscription_topics(%{thread_id: post.id}, bob) == [post.id]
    end

    test "a user who cannot read the thread is DENIED (no leak of private replies)" do
      alice = fake_user!()
      bob = fake_user!()
      # the "mentions" boundary has no preset ACLs → creator-only.
      secret = fake_post!(alice, "mentions", %{post_content: %{html_body: "secret"}})
      assert Feeds.subscription_topics(%{thread_id: secret.id}, bob) == []
    end

    test "an unauthenticated client cannot subscribe to a non-public thread" do
      alice = fake_user!()
      secret = fake_post!(alice, "mentions", %{post_content: %{html_body: "secret"}})
      assert Feeds.subscription_topics(%{thread_id: secret.id}, nil) == []
    end

    test "an unknown/non-existent thread id resolves to empty" do
      assert Feeds.subscription_topics(%{thread_id: "01J0THREAD0000000000000000"}, fake_user!()) ==
               []
    end
  end

  describe "subscription_topics/2 feeds" do
    test "feed_name 'notifications' scopes to the viewer's notifications feed" do
      user = fake_user!()

      assert Feeds.subscription_topics(%{feed_name: "notifications"}, user) ==
               [Feeds.my_feed_id(:notifications, user)]
    end

    test "feed_name 'my' returns the viewer's home feeds, all binary ids" do
      user = fake_user!()
      topics = Feeds.subscription_topics(%{feed_name: "my"}, user)
      assert is_list(topics)
      assert Enum.all?(topics, &is_binary/1)
    end

    test "a user-scoped feed without a user resolves to empty (can't scope)" do
      assert Feeds.subscription_topics(%{feed_name: "my"}, nil) == []
    end

    test "neither feed_name nor thread_id resolves to empty" do
      assert Feeds.subscription_topics(%{}, fake_user!()) == []
      assert Feeds.subscription_topics(%{feed_name: nil, thread_id: nil}, fake_user!()) == []
    end
  end
end
