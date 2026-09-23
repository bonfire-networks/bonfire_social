defmodule Bonfire.Social.NotificationCategoryFiltersTest do
  @moduledoc """
  A notification category used as a condition selects what the category says it selects.

  `notification_categories` and `exclude_notification_categories` are how the centre's switches and the Mastodon API's `types[]`/`exclude_types[]` ask for a category, and they reach `Notifications.query_filters_for/2` rather than restating it, so a switch hides exactly what the chip shows. The interesting categories are the two a list of verbs cannot express: Mentions (anything naming you) and Replies (without mentioning you), which is a reply *and* not naming you, and so has to be negated as one condition.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Likes
  alias Bonfire.Posts
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 10)

    me = Fake.fake_user!()
    other = Fake.fake_user!()
    bystander = Fake.fake_user!()

    my_post = fake_post!(me, "public", %{post_content: %{html_body: "my post"}})

    {:ok, naming_me} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "hey @#{me.character.username}"}}
      )

    {:ok, reply_naming_me} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering @#{me.character.username}"},
          reply_to_id: id(my_post)
        }
      )

    {:ok, reply_naming_nobody_i_am} =
      Posts.publish(
        current_user: other,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "answering @#{bystander.character.username} instead"},
          reply_to_id: id(my_post)
        }
      )

    {:ok, _like} = Likes.like(other, my_post)

    {:ok,
     me: me,
     my_post: my_post,
     naming_me: naming_me,
     reply_naming_me: reply_naming_me,
     reply_naming_nobody_i_am: reply_naming_nobody_i_am}
  end

  defp notifications(me, filters),
    do: FeedLoader.feed(:notifications, filters, current_user: me)

  defp contains?(feed, me, object), do: FeedLoader.feed_contains?(feed, object, current_user: me)

  test "unfiltered, every fixture is in my notifications", ctx do
    feed = notifications(ctx.me, %{})

    assert contains?(feed, ctx.me, ctx.naming_me)
    assert contains?(feed, ctx.me, ctx.reply_naming_me)
    assert contains?(feed, ctx.me, ctx.reply_naming_nobody_i_am)
    # the like's object is my post, which is how a like is found
    assert contains?(feed, ctx.me, ctx.my_post)
  end

  test "Mentions selects what names me, replies included, and nothing else", ctx do
    feed = notifications(ctx.me, %{notification_categories: [:mention]})

    assert contains?(feed, ctx.me, ctx.naming_me)
    assert contains?(feed, ctx.me, ctx.reply_naming_me)
    refute contains?(feed, ctx.me, ctx.reply_naming_nobody_i_am)
    refute contains?(feed, ctx.me, ctx.my_post)
  end

  test "hiding Replies (without mentioning you) keeps the reply that names me, since that is a mention",
       ctx do
    feed = notifications(ctx.me, %{exclude_notification_categories: [:extra_replies]})

    refute contains?(feed, ctx.me, ctx.reply_naming_nobody_i_am)
    assert contains?(feed, ctx.me, ctx.reply_naming_me)
    assert contains?(feed, ctx.me, ctx.naming_me)
    assert contains?(feed, ctx.me, ctx.my_post)
  end

  test "hiding Mentions hides replies that name me too, and keeps the reply that does not", ctx do
    feed = notifications(ctx.me, %{exclude_notification_categories: [:mention]})

    refute contains?(feed, ctx.me, ctx.naming_me)
    refute contains?(feed, ctx.me, ctx.reply_naming_me)
    assert contains?(feed, ctx.me, ctx.reply_naming_nobody_i_am)
    assert contains?(feed, ctx.me, ctx.my_post)
  end

  test "a category that is verbs alone is a plain condition", ctx do
    feed = notifications(ctx.me, %{notification_categories: [:react]})

    assert contains?(feed, ctx.me, ctx.my_post)
    refute contains?(feed, ctx.me, ctx.naming_me)
    refute contains?(feed, ctx.me, ctx.reply_naming_me)
  end
end
