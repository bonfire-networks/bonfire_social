defmodule Bonfire.Social.NotificationAudiencesTest do
  @moduledoc """
  Who you hear from: a person can hide notifications from people they don't follow, and from people who don't follow them. Hidden ones stay out of every normal view of the notifications feed and are still there to find, and anything with no one behind it (an admin broadcast) is never hidden.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Likes
  alias Bonfire.Common.Settings
  import Bonfire.Posts.Fake

  setup do
    me = fake_user!()
    stranger = fake_user!()
    followed = fake_user!()
    follower = fake_user!()

    {:ok, _} = Follows.follow(me, followed)
    {:ok, _} = Follows.follow(follower, me)

    {:ok, me: me, stranger: stranger, followed: followed, follower: follower}
  end

  defp hide(me, audience) do
    current_user(Settings.put([:notifications, :audience, audience], :hide, current_user: me))
  end

  # a post of mine liked by someone, so the like is in my notifications with them as its subject
  defp liked_by(me, liker) do
    post = fake_post!(me, "public", %{post_content: %{html_body: "liked by someone"}})
    {:ok, _} = Likes.like(liker, post)
    post
  end

  defp notified?(me, post, opts \\ []),
    do: FeedLoader.feed_contains?(:notifications, post, Keyword.merge([current_user: me], opts))

  test "hiding people you don't follow keeps out a stranger's like and not a followed person's",
       %{
         me: me,
         stranger: stranger,
         followed: followed
       } do
    from_stranger = liked_by(me, stranger)
    from_followed = liked_by(me, followed)

    # the positive first: before hiding, both are there
    assert notified?(me, from_stranger)

    me = hide(me, :not_followed)

    refute notified?(me, from_stranger)
    assert notified?(me, from_followed)
  end

  test "hiding people who don't follow you keeps out a stranger's like and not a follower's", %{
    me: me,
    stranger: stranger,
    follower: follower
  } do
    from_stranger = liked_by(me, stranger)
    from_follower = liked_by(me, follower)

    me = hide(me, :not_following)

    refute notified?(me, from_stranger)
    assert notified?(me, from_follower)
  end

  test "hiding both keeps only people who are both", %{
    me: me,
    followed: followed,
    follower: follower
  } do
    mutual = fake_user!()
    {:ok, _} = Follows.follow(me, mutual)
    {:ok, _} = Follows.follow(mutual, me)

    from_mutual = liked_by(me, mutual)
    from_followed_only = liked_by(me, followed)
    from_follower_only = liked_by(me, follower)

    me = me |> hide(:not_followed) |> hide(:not_following)

    assert notified?(me, from_mutual)
    refute notified?(me, from_followed_only)
    refute notified?(me, from_follower_only)
  end

  defp mentioning(author, me, opts \\ []) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs:
          Map.merge(
            %{post_content: %{html_body: "@#{me.character.username} hello"}},
            Map.new(opts)
          ),
        boundary: "public"
      )

    post
  end

  test "hiding mentions from people you don't follow keeps a stranger's mention out, not a followed person's",
       %{me: me, stranger: stranger, followed: followed} do
    from_stranger = mentioning(stranger, me)
    from_followed = mentioning(followed, me)
    # a like from the same stranger isn't a mention, so this row leaves it
    liked = liked_by(me, stranger)

    me = hide(me, :not_followed_making_contact)

    refute notified?(me, from_stranger)
    assert notified?(me, from_followed)
    assert notified?(me, liked)
  end

  # the "Mentions, unless they're replying to you" row was replaced by "People you don't follow, unless they're replying to you", tested below
  # test "hiding mentions unless they're replying to you keeps a mention in a reply to you, not one elsewhere",
  #      %{me: me, stranger: stranger} do
  #   mine = fake_post!(me, "public", %{post_content: %{html_body: "my thread"}})
  #   in_reply_to_me = mentioning(stranger, me, reply_to_id: mine.id)
  #   elsewhere = mentioning(stranger, me)
  #
  #   me = hide(me, :mentions_not_replying)
  #
  #   assert notified?(me, in_reply_to_me)
  #   refute notified?(me, elsewhere)
  # end

  test "hiding strangers making contact keeps their reply to you and their like, and hides their mention elsewhere",
       %{me: me, stranger: stranger, followed: followed} do
    mine = fake_post!(me, "public", %{post_content: %{html_body: "my thread"}})
    in_reply_to_me = mentioning(stranger, me, reply_to_id: mine.id)
    elsewhere = mentioning(stranger, me)
    # not a mention or a message, so not making contact
    liked = liked_by(me, stranger)
    from_followed = mentioning(followed, me)

    me = hide(me, :not_followed_making_contact)

    assert notified?(me, in_reply_to_me)
    assert notified?(me, from_followed)
    assert notified?(me, liked)
    refute notified?(me, elsewhere)
  end

  # an account's id dates from when it was first stored here: its registration, or when a remote one was first seen
  test "subject_known_since_days matches rows from accounts known here for at most that many days",
       %{me: me, stranger: stranger} do
    liked = liked_by(me, stranger)

    assert known_within?(me, liked, 30), "the stranger was created just now, so within 30 days"
    refute known_within?(me, liked, 0), "and not within none"
  end

  defp known_within?(me, object, days) do
    FeedLoader.feed(
      %{feed_name: :notifications, subject_known_since_days: days},
      current_user: me
    )
    |> FeedLoader.feed_contains?(object, current_user: me)
  end

  test "hiding new accounts keeps out a like from an account created just now", %{
    me: me,
    stranger: stranger
  } do
    liked = liked_by(me, stranger)

    # the positive first
    assert notified?(me, liked)

    me = hide(me, :new_accounts)

    refute notified?(me, liked)
  end

  # the Hidden chip, read as the chip bar reads any chip
  defp in_hidden?(me, object) do
    FeedLoader.feed(:notifications, %{notification_categories: [:hidden]}, current_user: me)
    |> FeedLoader.feed_contains?(object, current_user: me)
  end

  test "the Hidden chip shows what the switches keep out, and nothing else", %{
    me: me,
    stranger: stranger,
    followed: followed
  } do
    from_stranger = liked_by(me, stranger)
    from_followed = liked_by(me, followed)

    me = hide(me, :not_followed)

    assert in_hidden?(me, from_stranger)
    refute in_hidden?(me, from_followed)
  end

  test "with nothing hidden, the Hidden chip is empty", %{me: me, stranger: stranger} do
    liked = liked_by(me, stranger)

    # the positive first: it's in the notifications
    assert notified?(me, liked)
    refute in_hidden?(me, liked)
  end

  # a view of audiences, not a kind of notification, so it has no row of its own in the preferences (and the Mastodon list keeps what's hidden: `notification_preferences_ignored_test.exs`)
  test "the Hidden chip has no preference row", %{} do
    refute :hidden in Enum.map(Bonfire.Social.Notifications.categories_shown(:row), &elem(&1, 0))
  end

  test "a reader asking for everything still gets what's hidden, as the Mastodon list does", %{
    me: me,
    stranger: stranger
  } do
    from_stranger = liked_by(me, stranger)
    me = hide(me, :not_followed)

    assert notified?(me, from_stranger, include_hidden: true)
  end
end
