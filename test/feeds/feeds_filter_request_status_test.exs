defmodule Bonfire.Social.FeedsFilterRequestStatusTest do
  @moduledoc """
  A feed can pick asks by where they stand: still waiting, accepted, or ignored.

  `Request` records the answer as `accepted_at` or `ignored_at`, and an ask's activity shares the Request's id (the same mixin key the quote-ask preload relies on when it reads `activity.edge`), so the filter is a join on equal ids plus a test per status, with no index or migration needed.

  The states differ in kind, which is why this is a status rather than a yes/no: ignoring is reversible ("not now") and leaves the row so the ask can be reconsidered, while accepting is done. Accepting a *follow* ask deletes its activity outright (`Follows.accept/2` goes through `Requests.accept_and_delete/3`), so an accepted ask that stays in a feed is a quote ask, accepted through the same `Requests.accept/2` used here.

  `:pending` also keeps what is not an ask at all, since that is what lets it quiet a mixed feed; the mixed case is pinned because a left join with the wrong null tolerance quietly empties a feed of ordinary posts.

  Asks are told apart by their own ids rather than with `feed_contains?/3`, which resolves a request to its object: every ask here is addressed to the same person, so that probe would match whichever ask came first. The same shared object is why every feed here turns `show_objects_only_once` off, as the notifications preset does: left on, asks to one person collapse into a single row.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Requests
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 10)

    account = fake_account!()
    # asking rather than following outright is what the followed person's own setting decides
    me = Fake.fake_user!(account, %{}, request_before_follow: true)

    {:ok, waiting} = Follows.follow(Fake.fake_user!(account), me)
    {:ok, ignored} = Follows.follow(Fake.fake_user!(account), me)
    {:ok, accepted} = Follows.follow(Fake.fake_user!(account), me)

    assert {:ok, %{ignored_at: %DateTime{}}} = Follows.ignore(ignored, current_user: me)
    # the function `Quotes` accepts with, which keeps the row; `Follows.accept/2` would delete it
    assert {:ok, %{accepted_at: %DateTime{}}} = Requests.accept(accepted, current_user: me)

    post = fake_post!(me, "local", %{post_content: %{html_body: "an ordinary post"}})

    {:ok, me: me, waiting: waiting, ignored: ignored, accepted: accepted, post: post}
  end

  defp activity_ids(%{edges: edges}),
    do: MapSet.new(edges, &(e(&1, :activity, :id, nil) || e(&1, :id, nil)))

  defp asks(me, filters) do
    FeedLoader.feed(
      :custom,
      Map.merge(%{activity_types: [:request], show_objects_only_once: false}, filters),
      current_user: me,
      include_requests: true
    )
    |> activity_ids()
  end

  test "pending is what is still waiting", %{
    me: me,
    waiting: waiting,
    ignored: ignored,
    accepted: accepted
  } do
    ids = asks(me, %{request_status: [:pending]})

    # the positive first: it is also what proves an ask's activity carries the Request's id, which the join depends on
    assert id(waiting) in ids
    refute id(ignored) in ids
    refute id(accepted) in ids
  end

  test "ignored is what somebody set aside, so it can be reconsidered", %{
    me: me,
    waiting: waiting,
    ignored: ignored,
    accepted: accepted
  } do
    ids = asks(me, %{request_status: [:ignored]})

    assert id(ignored) in ids
    refute id(waiting) in ids
    refute id(accepted) in ids
  end

  test "accepted is what was agreed to", %{
    me: me,
    waiting: waiting,
    ignored: ignored,
    accepted: accepted
  } do
    ids = asks(me, %{request_status: [:accepted]})

    assert id(accepted) in ids
    refute id(waiting) in ids
    refute id(ignored) in ids
  end

  test "several statuses are either of them", %{
    me: me,
    waiting: waiting,
    ignored: ignored,
    accepted: accepted
  } do
    ids = asks(me, %{request_status: [:pending, :ignored]})

    assert id(waiting) in ids
    assert id(ignored) in ids
    refute id(accepted) in ids
  end

  test "in a mixed feed, pending hides answered asks and keeps what is not an ask", %{
    me: me,
    waiting: waiting,
    ignored: ignored,
    post: post
  } do
    feed =
      FeedLoader.feed(
        :custom,
        %{
          activity_types: [:request, :create],
          request_status: [:pending],
          show_objects_only_once: false
        },
        current_user: me,
        include_requests: true
      )

    assert FeedLoader.feed_contains?(feed, post, current_user: me),
           "an ordinary post has no request row at all, and a null-intolerant join would drop it"

    ids = activity_ids(feed)
    assert id(waiting) in ids
    refute id(ignored) in ids
  end

  test "without the filter all three asks are there, so the filter is what picks", %{
    me: me,
    waiting: waiting,
    ignored: ignored,
    accepted: accepted
  } do
    ids = asks(me, %{})

    assert id(waiting) in ids
    assert id(ignored) in ids
    assert id(accepted) in ids
  end
end
