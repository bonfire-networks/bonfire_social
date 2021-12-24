defmodule Bonfire.Social.MessagesTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Messages, Feeds, FeedActivities}
  alias Bonfire.Me.Fake

  test "can message a user" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    msg = "hey receiver, you have an epic text message"
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: msg}}
    assert {:ok, message} = Messages.send(sender, attrs)

    assert message.post_content.html_body =~ msg
  end

  test "can list messages I sent" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(sender)
    fp = List.first(feed)

    assert fp.activity.id == message.activity.id
  end

  test "can list messages I received" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(receiver)
    fp = List.first(feed)

    assert fp.activity.id == message.activity.id
  end

  test "can list messages I sent to a specific person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    other = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(sender)
    assert List.first(feed).activity.id == message.activity.id

    assert %{edges: feed} = Messages.list(receiver)
    assert List.first(feed).activity.id == message.activity.id

    assert %{edges: feed} = Messages.list(sender, receiver)
    assert List.first(feed).activity.id == message.activity.id

    assert %{edges: feed} = Messages.list(receiver, sender)
    assert List.first(feed).activity.id == message.activity.id

    # random person can't see them
    assert %{edges: []} = Messages.list(other)
    assert %{edges: []} = Messages.list(sender, other)
    assert %{edges: []} = Messages.list(other, sender)
  end

  test "messages addressed to sender appear in my notifications" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, m} = Messages.send(sender, attrs)

    assert %{edges: feed} = FeedActivities.feed(:notifications, receiver)
    fp = List.first(feed)
    assert %{id: _} = fp

    assert fp.activity.id == m.activity.id
  end

  test "messaging someone does NOT appear in my own notifications" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: []} = FeedActivities.feed(:notifications, sender)
  end

  test "messaging someone else does NOT appear in a 3rd party's notifications" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    third = Fake.fake_user!()

    assert %{edges: []} = FeedActivities.feed(:notifications, third)
  end

  test "messaging someone does NOT appear in their feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: []} = FeedActivities.my_feed(receiver)
  end

  test "messaging someone does NOT appear in their instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    assert %{edges: []} = FeedActivities.feed(feed_id, receiver)

  end

  test "messaging someone does NOT appear in my instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    assert %{edges: []} = FeedActivities.feed(feed_id, sender)

  end

  test "messaging someone does NOT appear in a 3rd party's instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    third = Fake.fake_user!()

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    assert %{edges: []} = FeedActivities.feed(feed_id, third)
  end

  test "messaging someone does NOT appear in the public instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    assert %{edges: []} = FeedActivities.feed(feed_id, nil)
  end


end
