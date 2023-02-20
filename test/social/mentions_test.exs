defmodule Bonfire.Social.MentionsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Me.Fake
  import Bonfire.Boundaries.Debug

  test "can post with a mention" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    msg = "hey @#{mentioned.character.username} you have an epic text message"
    attrs = %{post_content: %{html_body: msg}}

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    # debug(post)
    assert String.contains?(post.post_content.html_body, "epic text message")
  end

  test "can see post mentioning me in my notifications (using the 'mentions' preset), ignoring boundaries" do
    poster = Fake.fake_user!()
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{me.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: poster,
               post_attrs: attrs,
               boundary: "mentions"
             )

    assert FeedActivities.feed_contains?(:notifications, mention,
             current_user: me,
             skip_boundary_check: true
           )
  end

  test "can see post mentioning me in my notifications (using the 'mentions' preset), with boundaries enforced" do
    poster = Fake.fake_user!()
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{me.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: poster,
               post_attrs: attrs,
               boundary: "mentions"
             )

    assert FeedActivities.feed_contains?(:notifications, mention, current_user: me)
  end

  # duplicate of previous test
  #  test "mentioning someone appears in their notifications feed, if using the 'mentions' preset" do
  #   me = Fake.fake_user!()
  #   mentioned = Fake.fake_user!()

  #   attrs = %{
  #     post_content: %{
  #       html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
  #     }
  #   }

  #   assert {:ok, mention} =
  #            Posts.publish(
  #              current_user: me,
  #              post_attrs: attrs,
  #              boundary: "mentions"
  #            )

  #   # debug_my_grants_on(mentioned, mention)

  #   assert FeedActivities.feed_contains?(:notifications, mention, current_user: mentioned)
  # end

  test "mentioning someone does not appear in my own notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    refute FeedActivities.feed_contains?(:notifications, mention, current_user: me)
  end

  test "mentioning someone else does not appear in a 3rd party's notifications" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    third = Fake.fake_user!()

    refute FeedActivities.feed_contains?(:notifications, mention, current_user: third)
  end

  test "mentioning someone does not appear in their home feed, if they don't follow me, and have disabled notifications in home feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    {:ok, %{assign_context: assigns}} =
      Bonfire.Me.Settings.put(
        [Bonfire.Social.Feeds, :my_feed_includes, :notifications],
        false,
        current_user: mentioned
      )

    mentioned =
      (assigns[:current_user] || mentioned)
      |> info("user with updated settings")

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    refute FeedActivities.feed_contains?(:my, mention, current_user: mentioned)
  end

  test "mentioning someone appears in their home feed, if they don't follow me, and have enabled notifications in home feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    # Bonfire.Me.Settings.put([Bonfire.Social.Feeds, :my_feed_includes, :notifications], true, current_user: mentioned) # default anyway

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    assert FeedActivities.feed_contains?(:my, mention, current_user: mentioned)
  end

  test "mentioning someone DOES NOT appear (if NOT using the preset 'mentions' boundary) in their instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    refute FeedActivities.feed_contains?(:local, mention, current_user: mentioned)
  end

  test "mentioning someone appears in my instance feed (if using 'local' preset)" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "local"
             )

    assert FeedActivities.feed_contains?(:local, mention, current_user: me)
  end

  test "mentioning someone does not appear in a 3rd party's instance feed (if not included in circles)" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    third = Fake.fake_user!()
    refute = FeedActivities.feed_contains?(:local, mention, current_user: third)
  end

  test "mentioning someone with 'local' preset does not appear *publicly* in the instance feed" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()

    attrs = %{
      post_content: %{
        html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "local"
             )

    refute FeedActivities.feed_contains?(:local, mention)
  end
end
