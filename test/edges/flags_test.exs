defmodule Bonfire.Social.FlagsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Flags
  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users

  import Bonfire.Boundaries.Debug

  test "flag works, and can check if I flagged something, and if I did not flag something" do
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

    assert true == Flags.flagged?(me, flagged)

    another = Fake.fake_user!()

    assert false == Flags.flagged?(another, flagged)
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

    # User can list their own flags
    assert %{edges: [fetched_flag]} = Flags.list_my(current_user: me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id

    # # FIXME: verify flag appears in my flags feed
    # assert %{edges: [%{activity: feed_flag}]} = 
    #          FeedActivities.feed(:my_flags, current_user: me)
    # assert flag.id == feed_flag.id
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

    # Admin can list all flags
    assert %{edges: [fetched_flag]} = Flags.list(scope: :instance, current_user: me)
    assert flag.id == fetched_flag.id

    # Admin can see all flags in flagged_content feed
    assert %{edges: [%{activity: feed_flag}]} =
             FeedActivities.feed(:flagged_content, current_user: me, preload_context: :all)

    assert flag.id == feed_flag.id
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

    # Admin can list who flagged an object
    assert %{edges: [fetched_flag]} =
             Flags.list(scope: flagged, scope_type: :objects, current_user: me)

    assert flag.id == fetched_flag.edge.id

    # Admin can see flag in their notifications feed
    assert %{edges: [%{activity: feed_flag}]} =
             FeedActivities.feed(:notifications, current_user: me)

    assert flag.id == feed_flag.id
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

    # Admin can list someone else's flags
    assert %{edges: [fetched_flag]} =
             Flags.list(scope: someone, scope_type: :subjects, current_user: me)

    assert flag.id == fetched_flag.edge.id

    # Admin can see the flag in flagged_content feed
    assert %{edges: [%{activity: feed_flag}]} =
             FeedActivities.feed(:flagged_content, current_user: me, preload_context: :all)

    assert flag.id == feed_flag.id
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

    # Admin can list someone else's flags and see comment
    assert %{edges: [fetched_flag]} =
             Flags.list_preloaded(scope: someone, scope_type: :subjects, current_user: me)

    assert flag.id == fetched_flag.id
    assert comment == fetched_flag.named.name

    # Verify flag with comment appears in notifications feed
    assert %{edges: [%{activity: fetched_flag}]} =
             FeedActivities.feed(:notifications, current_user: me, preload_context: :all)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.object_id
    assert flag.edge.subject_id == fetched_flag.subject_id
    assert comment == fetched_flag.named.name

    # Verify flag with comment appears in flagged_content feed
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

  test "cannot list all flags as non-admin" do
    someone = Fake.fake_user!()
    me = Fake.fake_user!()

    # just in case
    Users.revoke_admin(me)
    Users.revoke_admin(someone)

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

    assert {:ok, _flag} = Flags.flag(someone, flagged)

    # Non-admin cannot list all flags
    assert {:error, :not_permitted} = Flags.list(scope: :instance, current_user: me)

    # Non-admin should not see flags in flagged_content feed
    assert {:error, :not_permitted} = FeedActivities.feed(:flagged_content, current_user: me)
  end

  test "cannot list someone else's flags as non-admin" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    another_user = Fake.fake_user!()

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

    assert {:ok, _flag} = Flags.flag(someone, flagged)

    # Non-admin cannot list someone else's flags
    assert {:error, :not_permitted} =
             Flags.list(scope: someone, scope_type: :subjects, current_user: another_user)

    # Non-admin should not see someone else's flags in notifications
    notifications = FeedActivities.feed(:notifications, current_user: another_user)

    flag_notifications =
      Enum.filter(notifications.edges, fn edge ->
        edge.activity.verb_id == Bonfire.Data.Social.Flag.verb_id()
      end)

    assert [] = flag_notifications
  end

  test "cannot list something's flaggers as non-admin" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    another_user = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, flagged} =
             Posts.publish(
               current_user: another_user,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, _flag} = Flags.flag(someone, flagged)

    # Non-admin cannot see who flagged something
    assert {:error, :not_permitted} =
             Flags.list(scope: flagged, scope_type: :objects, current_user: me)

    # Non-admin should not see flag notifications about their content
    notifications = FeedActivities.feed(:notifications, current_user: another_user)

    flag_notifications =
      Enum.filter(notifications.edges, fn edge ->
        edge.activity.verb_id == Bonfire.Data.Social.Flag.verb_id()
      end)

    assert [] = flag_notifications
  end
end
