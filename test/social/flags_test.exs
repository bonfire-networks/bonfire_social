defmodule Bonfire.Social.FlagsTest do

  alias Bonfire.Social.{Flags, Posts, FeedActivities}
  alias Bonfire.Me.{Fake, Users}
  import Bonfire.Social.Utils
  use Bonfire.DataCase

  test "flag works" do

    me = Fake.fake_user!()

    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")

    assert {:ok, %{activity: activity}} = Flags.flag(me, flagged)
    # IO.inspect(activity)
    assert activity.subject.id == me.id
    assert activity.object.id == flagged.id

  end

  test "can check if I flagged something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, _} = Flags.flag(me, flagged)

    assert true == Flags.flagged?(me, flagged)
  end

  test "can check if I did not flag something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")

    assert false == Flags.flagged?(me, flagged)
  end

  test "can unflag something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, _} = Flags.flag(me, flagged)

    Flags.unflag(me, flagged)
    assert false == Flags.flagged?(me, flagged)
  end

  test "can list my flags" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(someone, attrs, "public")
    assert {:ok, flag} = Flags.flag(me, flagged)
    assert %{edges: [fetched_flag]} =
      Flags.list_paginated([subject: me], current_user: me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list all flags (as an admin)" do
    me = Fake.fake_user!()
    me = Users.make_admin(me)
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} = Flags.list_paginated([:all], current_user: me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list something's flaggers (as an admin)" do
    me = Fake.fake_user!()
    me = Users.make_admin(me)
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, flagged)
    assert %{edges: [fetched_flag]} =
      Flags.list_paginated([object: flagged], current_user: me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list someone else's flags (as an admin)" do
    me = Fake.fake_user!()
    me = Users.make_admin(me)
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} =
      Flags.list_paginated([subject: someone], current_user: me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "see a flag of something in my notifications (as an admin)" do
    me = Fake.fake_user!()
    me = Users.make_admin(me)
    someone = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}

    assert {:ok, post} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, post)
    debug_object_acls(flag)
    assert %{edges: [feed_publish]} =
      FeedActivities.feed(:notifications, current_user: me)
    assert activity = feed_publish.activity
    assert flag.edge.object_id == post.id
    assert flag.edge.subject_id == someone.id
  end

end
