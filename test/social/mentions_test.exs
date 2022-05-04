defmodule Bonfire.Social.MentionsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.{Posts, Feeds, FeedActivities}
  alias Bonfire.Me.Fake
  import Bonfire.Boundaries.Debug

  test "can post with a mention" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    msg = "hey @#{mentioned.character.username} you have an epic text message"
    attrs = %{post_content: %{html_body: msg}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    # debug(post)
    assert String.contains?(post.post_content.html_body, "epic text message")
  end

  test "can see post mentioning me in my notifications (using the 'mentions' preset), ignoring boundaries" do
    poster = Fake.fake_user!()
    me = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{me.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: poster, post_attrs: attrs, boundary: "mentions")
    assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: me, skip_boundary_check: true)
    # debug(feed)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "can see post mentioning me in my notifications (using the 'mentions' preset), with boundaries enforced" do
    poster = Fake.fake_user!()
    me = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{me.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: poster, post_attrs: attrs, boundary: "mentions")
    assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: me)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning someone does not appear in my own notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: []} = FeedActivities.feed(:notifications, current_user: me)
  end

  test "mentioning someone else does not appear in a 3rd party's notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    third = Fake.fake_user!()
    assert %{edges: []} = FeedActivities.feed(:notifications, current_user: third)
  end

  test "mentioning someone appears in their notifications feed, if using the 'mentions' preset" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    debug_my_grants_on(mentioned, mention)
    assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning someone does not appear in their feed, if using the 'mentions' preset" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}

    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: []} = FeedActivities.my_feed(mentioned)
  end

  test "mentioning someone DOES NOT appear (if NOT using the preset 'mentions' boundary) in their instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    assert %{edges: []} = FeedActivities.feed(:local, current_user: mentioned)
  end

  test "mentioning someone appears in my instance feed (if using 'local' preset)" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "local")
    assert %{edges: feed} = FeedActivities.feed(:local, current_user: me)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning someone does not appear in a 3rd party's instance feed (if not included in circles)" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    third = Fake.fake_user!()
    assert %{edges: []} = FeedActivities.feed(:local, current_user: third)
  end

  test "mentioning someone with 'local' preset does not appear *publicly* in the instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "local")
    assert %{edges: []} = FeedActivities.feed(:local)
  end


end
