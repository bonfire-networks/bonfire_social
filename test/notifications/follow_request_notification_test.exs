defmodule Bonfire.Social.FollowRequestNotificationTest do
  @moduledoc """
  That an ask to follow arrives as an ask to follow, all the way to the row that offers to accept it.

  Two things have to hold for that button to appear: the ask reaches the notifications feed, and it reads as `:follow_request` rather than the bare `:request` every ask is stored as. Both failures look identical from the page (no Accept button), so they are asserted apart.

  A feed loads the edge for quote asks alone, so a follow ask arrives without the one thing that says what was asked for, and is read as a follow ask because that is the only other kind there is. This pins that: the row a person sees is the reason the assumption exists.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Me.Fake

  setup do
    account = fake_account!()
    # asking rather than following outright is what the followed person's own setting decides
    me = Fake.fake_user!(account, %{}, request_before_follow: true)
    someone = Fake.fake_user!(account, %{}, request_before_follow: true)

    {:ok, _request} = Follows.follow(someone, me)
    assert true == Follows.requested?(someone, me)

    {:ok, me: me, someone: someone}
  end

  # the opts the `:notifications` preset carries, since a feed that does not ask for asks is not shown them
  defp notifications_opts(me),
    do: [current_user: me, limit: 100, include_flags: :mediate, include_requests: true]

  test "the ask reaches my notifications feed", %{me: me} do
    assert FeedLoader.feed_contains?(:notifications, me, notifications_opts(me))
  end

  test "and reads as an ask to follow, which is what offers the Accept button", %{me: me} do
    # the match comes back as the activity, which is what a row is rendered from
    assert activity = FeedLoader.feed_contains?(:notifications, me, notifications_opts(me))

    # the edge a quote ask would carry is absent here, which is exactly the case the assumption covers
    assert is_nil(e(activity, :edge, :table_id, nil))

    assert Activities.experienced_as(activity, me) == :follow_request
  end
end
