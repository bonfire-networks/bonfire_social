defmodule Bonfire.Social.MentionsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Posts, Feeds, FeedActivities}
  alias Bonfire.Me.Fake

  test "can post with a mention" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(me, attrs)

    assert mention.activity.activity.object.created.creator_id == me.id
  end

  test "can see activities mentioning me (as part of notifications)" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    assert %{entries: feed} = FeedActivities.feed(:notifications, mentioned)
    fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "mentioning someone does not appear in my own notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    assert %{entries: []} = FeedActivities.feed(:notifications, me)
  end

  test "mentioning someone else does not appear in a 3rd party's notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    third = Fake.fake_user!()

    assert %{entries: []} = FeedActivities.feed(:notifications, third)
  end

  @tag :skip # FIXME!
  test "mentioning someone appears in their feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    assert %{entries: feed} = FeedActivities.my_feed(mentioned)
     fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "mentioning someone appears in their instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: feed} = FeedActivities.feed(feed_id, mentioned)
     fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "mentioning someone appears in my instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: feed} = FeedActivities.feed(feed_id, me)
    fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "mentioning someone does not appear in a 3rd party's instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    third = Fake.fake_user!()

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, third)
  end

  test "mentioning someone does not appear in the public instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, nil)
  end


end
