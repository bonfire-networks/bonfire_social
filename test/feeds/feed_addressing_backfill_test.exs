defmodule Bonfire.Social.FeedAddressingBackfillTest do
  @moduledoc """
  Phase 2: the local reclassify backfill. Legacy local-feed (`3SERS…`) rows must SPLIT by their
  original boundary into the new buckets — `local_public` if the activity was public, else
  `local_instance_only` — using the sibling guest-row signal (no ACL join). Written with feed
  addressing OFF (the default), so `Posts.publish` produces the LEGACY rows the backfill operates on.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Feeds.Addressing.Backfill, as: Backfill
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  @legacy_local "3SERSFR0MY0VR10CA11NSTANCE"
  @legacy_activity_pub "7EDERATEDW1THANACT1V1TYPVB"
  @guest "0AND0MSTRANGERS0FF1NTERNET"
  @local_public "7PVB11C0BJECTFR0M10CA1VSER"
  @local_instance_only "710CA10BJ0N1YF0R10CA1VSERS"
  @remote_public "7PVB11C0BJFR0MAREM0TEACT0R"
  @feed_publish_table "bonfire_data_social_feed_publish"

  setup do
    # this suite operates on LEGACY rows, so force write-addressing OFF (via the process tree, which
    # test-env Config.get checks first) — deterministic even under an ambient `FEED_ADDRESSING=1` run
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], false)
    :ok
  end

  defp publish!(author, boundary) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "backfill #{boundary}"}},
        boundary: boundary
      )

    post
  end

  defp feeds_of(post),
    do: FeedActivities.feeds_for_activity(e(post, :activity, :id, nil) || raise("no activity"))

  defp run_backfill, do: Backfill.base_query() |> repo().all() |> Backfill.migrate()

  test "reclassifies legacy local rows: public→local_public, local→local_instance_only" do
    author = Fake.fake_user!()
    public_post = publish!(author, "public")
    local_post = publish!(author, "local")

    # preconditions: both legacy-written to 3SERS, not yet in the new buckets; and the
    # classification signal is present (public has a guest row, local does not)
    assert @legacy_local in feeds_of(public_post)
    assert @legacy_local in feeds_of(local_post)
    refute @local_public in feeds_of(public_post)
    refute @local_instance_only in feeds_of(local_post)

    assert @guest in feeds_of(public_post),
           "public post has the legacy guest row (the split signal)"

    refute @guest in feeds_of(local_post), "local post has no guest row"

    run_backfill()

    # public post moved to local_public; local post moved to local_instance_only; 3SERS row dropped
    assert @local_public in feeds_of(public_post)
    refute @legacy_local in feeds_of(public_post)
    # the now-duplicate guest row is migrated away too (content lives in local_public)
    refute @guest in feeds_of(public_post),
           "redundant guest row dropped after moving to local_public"

    assert @local_instance_only in feeds_of(local_post)
    refute @legacy_local in feeds_of(local_post)
  end

  test "reclassifies legacy activity_pub rows to remote_public (unconditional)" do
    author = Fake.fake_user!()

    # a "mentions" post gets no legacy global row, so we isolate the remote route by inserting only a
    # 7EDER (activity_pub) row for its activity — exactly the shape a legacy remote-public ingest left
    post = publish!(author, "mentions")
    activity_id = e(post, :activity, :id, nil)

    repo().insert_all(@feed_publish_table, [
      %{id: Needle.ULID.dump!(activity_id), feed_id: Needle.ULID.dump!(@legacy_activity_pub)}
    ])

    assert @legacy_activity_pub in feeds_of(post)

    run_backfill()

    assert @remote_public in feeds_of(post)
    refute @legacy_activity_pub in feeds_of(post)
  end

  test "is idempotent: a second run is a no-op (rows already moved, none left in 3SERS)" do
    author = Fake.fake_user!()
    public_post = publish!(author, "public")

    run_backfill()
    before = feeds_of(public_post) |> Enum.sort()
    run_backfill()

    assert feeds_of(public_post) |> Enum.sort() == before
    assert @local_public in feeds_of(public_post)
    refute @legacy_local in feeds_of(public_post)
  end
end
