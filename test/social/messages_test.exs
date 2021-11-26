defmodule Bonfire.Social.MessagesTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Messages, Feeds, FeedActivities}
  alias Bonfire.Me.Fake

  test "can message a user" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    msg = "hey you have an epic text message"
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: msg}}
    assert {:ok, message} = Messages.send(me, attrs)

    assert message.post_content.html_body =~ msg
  end

  test "can list messages I sent" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    assert %{entries: feed} = Messages.list(me)
    fp = List.first(feed)

    assert fp.activity.id == message.activity.id
  end

  test "can list messages I received" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    attrs = %{to_circles: [me.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(other, attrs)

    assert %{entries: feed} = Messages.list(me)
    fp = List.first(feed)

    assert fp.activity.id == message.activity.id
  end

  test "can list messages I sent to a specific person" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    other = Fake.fake_user!()
    fourth = Fake.fake_user!()

    attrs = %{to_circles: [fourth.id], post_content: %{html_body: "<p>hey fourth, you have an epic html message</p>"}}
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    assert %{entries: feed} = Messages.list(me)
    assert List.first(feed).activity.id == message.activity.id

    assert %{entries: feed} = Messages.list(messaged)
    assert List.first(feed).activity.id == message.activity.id

    assert %{entries: feed} = Messages.list(me, messaged)
    assert List.first(feed).activity.id == message.activity.id

    assert %{entries: feed} = Messages.list(messaged, me)
    assert List.first(feed).activity.id == message.activity.id

    assert %{entries: []} = Messages.list(me, other)

    assert %{entries: []} = Messages.list(other, me)
  end

  test "messages addressed to me appear in my notifications" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    attrs = %{to_circles: [me.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, m} = Messages.send(other, attrs)

    assert %{entries: feed} = FeedActivities.feed(:notifications, me)
    fp = List.first(feed)
    assert %{} = fp

    assert fp.activity.id == m.activity.id
  end

  test "messaging someone does NOT appear in my own notifications" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    assert %{entries: []} = FeedActivities.feed(:notifications, me)
  end

  test "messaging someone else does NOT appear in a 3rd party's notifications" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    third = Fake.fake_user!()

    assert %{entries: []} = FeedActivities.feed(:notifications, third)
  end

  test "messaging someone does NOT appear in their feed" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    assert %{entries: []} = FeedActivities.my_feed(messaged)
  end

  test "messaging someone does NOT appear in their instance feed" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, messaged)

  end

  test "messaging someone does NOT appear in my instance feed" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, me)

  end

  test "messaging someone does NOT appear in a 3rd party's instance feed" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    third = Fake.fake_user!()

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, third)
  end

  test "messaging someone does NOT appear in the public instance feed" do
    me = Fake.fake_user!()
    messaged = Fake.fake_user!()
    attrs = %{to_circles: [messaged.id], post_content: %{html_body: "<p>hey, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(me, attrs)

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    assert %{entries: []} = FeedActivities.feed(feed_id, nil)
  end


end
