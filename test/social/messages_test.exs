defmodule Bonfire.Social.MessagesTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Messages, Feeds, FeedActivities}
  alias Bonfire.Me.Fake

  test "can message a user" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey you have an epic html message</p>"}}
    assert {:ok, mention} = Messages.send(me, attrs)

    assert mention.activity.activity.object.created.creator_id == me.id
  end

  test "can list messages I sent" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    assert %{entries: feed} = Messages.list(me)
    fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "can list messages I received" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    attrs = %{circles: [me.id], post_content: %{html_body: "<p>hey @#{me.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(other, attrs)

    assert %{entries: feed} = Messages.list(me)
    fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "can list messages I sent to a specific person" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    other = Fake.fake_user!()

    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    assert %{entries: feed} = Messages.list(me)
    assert List.first(feed).activity.id == mention.activity.activity.id

    assert %{entries: feed} = Messages.list(mentioned)
    assert List.first(feed).activity.id == mention.activity.activity.id

    assert %{entries: feed} = Messages.list(me, mentioned)
    assert List.first(feed).activity.id == mention.activity.activity.id

    assert %{entries: feed} = Messages.list(mentioned, me)
    assert List.first(feed).activity.id == mention.activity.activity.id

    assert %{entries: []} = Messages.list(me, other)

    assert %{entries: []} = Messages.list(other, me)
  end

  @tag :skip # FIXME!
  test "can see messages addressed to me (as part of notifications)" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    attrs = %{circles: [me.id], post_content: %{html_body: "<p>hey @#{me.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(other, attrs)

    assert %{entries: feed} = FeedActivities.feed(:notifications, me)
    fp = List.first(feed)

    assert fp.activity.id == mention.activity.activity.id
  end

  test "messaging someone does not appear in my own notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    assert %{entries: []} = FeedActivities.feed(:notifications, me)
  end

  test "messaging someone else does not appear in a 3rd party's notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    third = Fake.fake_user!()

    assert %{entries: []} = FeedActivities.feed(:notifications, third)
  end

  test "messaging someone does not appear in their feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    assert %{entries: []} = FeedActivities.my_feed(mentioned)
  end

  test "messaging someone does not appear in their instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, mentioned)

  end

  test "messaging someone does not appear in my instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, me)

  end

  test "mentioning someone does not appear in a 3rd party's instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    third = Fake.fake_user!()

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, third)
  end

  test "mentioning someone does not appear in the public instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{circles: [mentioned.id], post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Messages.send(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, nil)
  end


end
