defmodule Bonfire.Social.FlagsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Flags
  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users

  import Bonfire.Boundaries.Debug

  test "flag works" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, %{activity: activity}} = Flags.flag(me, flagged)
    # debug(activity)
    assert activity.subject_id == me.id
    assert activity.object_id == flagged.id
  end

  test "can check if I flagged something" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, _} = Flags.flag(me, flagged)

    assert true == Flags.flagged?(me, flagged)
  end

  test "can check if I did not flag something" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert false == Flags.flagged?(me, flagged)
  end

  test "can unflag something" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, _} = Flags.flag(me, flagged)

    Flags.unflag(me, flagged)
    assert false == Flags.flagged?(me, flagged)
  end

  test "can list my flags" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: someone,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, flag} = Flags.flag(me, flagged)

    # NOTE: we now use feed queries to list flags instead
    assert %{edges: [fetched_flag]} = Flags.list_paginated([subject: me], current_user: me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list all flags (as an admin)" do
    me = Fake.fake_user!()
    {:ok, me} = Users.make_admin(me)
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public",
               debug: true,
               crash: true
             )

    assert {:ok, flag} = Flags.flag(someone, flagged)

    # NOTE: we now use feed queries to list flags instead
    assert %{edges: [fetched_flag]} = Flags.list_paginated([:all], current_user: me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list something's flaggers (as an admin)" do
    me = Fake.fake_user!()
    {:ok, me} = Users.make_admin(me)
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, flag} = Flags.flag(someone, flagged)

    # NOTE: we now use feed queries to list flags instead
    assert %{edges: [fetched_flag]} = Flags.list_paginated([object: flagged], current_user: me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list someone else's flags (as an admin)" do
    me = Fake.fake_user!()
    {:ok, me} = Users.make_admin(me)
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, flag} = Flags.flag(someone, flagged)

    # NOTE: we now use feed queries to list flags instead
    assert %{edges: [fetched_flag]} = Flags.list_paginated([subject: someone], current_user: me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can include a comment with a flag, which admin can see" do
    me = Fake.fake_user!()
    {:ok, me} = Users.make_admin(me)
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public",
               debug: true,
               crash: true
             )

    comment = "this is spam"
    assert {:ok, flag} = Flags.flag(someone, flagged, comment: comment)

    # NOTE: we now use feed queries to list flags instead
    assert %{edges: [fetched_flag]} = Flags.list_paginated([:all], current_user: me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
    assert comment == fetched_flag.named.name

    assert %{edges: [%{activity: fetched_flag}]} =
             FeedActivities.feed(:notifications, current_user: me, preload_context: :all)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.object_id
    assert flag.edge.subject_id == fetched_flag.subject_id
    assert comment == fetched_flag.named.name

    assert %{edges: [%{activity: fetched_flag}]} =
             FeedActivities.feed(:flagged_content, current_user: me, preload_context: :all)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.object_id
    assert flag.edge.subject_id == fetched_flag.subject_id
    assert comment == fetched_flag.named.name
  end

  test "see a flag of something in my notifications (as an admin)" do
    me = Fake.fake_user!()
    {:ok, me} = Users.make_admin(me)
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{html_body: "<p>hey you have an epic html post</p>"}
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, flag} = Flags.flag(someone, post)
    # debug_object_acls(flag)
    assert %{edges: [feed_publish]} = FeedActivities.feed(:notifications, current_user: me)

    assert activity = feed_publish.activity
    assert flag.edge.object_id == post.id
    assert flag.edge.subject_id == someone.id
  end
end
