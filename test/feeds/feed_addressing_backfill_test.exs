defmodule Bonfire.Social.FeedAddressingBackfillTest do
  @moduledoc """
  Phase 2: the local reclassify backfill. Legacy local-feed (`3SERS…`) rows must SPLIT by their
  original boundary into the new buckets — `local_public` if the activity was public, else
  `local_instance_only` — using the sibling guest-row signal (no ACL join). Written with feed
  addressing OFF (the default), so `Posts.publish` produces the LEGACY rows the backfill operates on.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Feeds.Addressing.Backfill, as: Backfill
  alias Bonfire.Social.Feeds.Addressing.Rollout
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

  defp run_backfill, do: Backfill.run()

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

  test "reclassifies legacy public_remote (guest sibling) → remote_public, but LEAVES addressed remote_custom (no guest sibling) in 7EDER" do
    author = Fake.fake_user!()

    # legacy public_remote ingest left BOTH a guest (0AND0M) and an activity_pub (7EDER) row:
    legacy_public = publish!(author, "mentions")
    lp = e(legacy_public, :activity, :id, nil)

    repo().insert_all(@feed_publish_table, [
      %{id: Needle.ULID.dump!(lp), feed_id: Needle.ULID.dump!(@legacy_activity_pub)},
      %{id: Needle.ULID.dump!(lp), feed_id: Needle.ULID.dump!(@guest)}
    ])

    # addressed remote_custom (non-public remote content): only a 7EDER row, NO guest sibling. `remote_custom`
    # reuses the legacy activity_pub id, so this is exactly the shape the addressed ingest path writes.
    custom_remote = publish!(author, "mentions")
    cr = e(custom_remote, :activity, :id, nil)

    repo().insert_all(@feed_publish_table, [
      %{id: Needle.ULID.dump!(cr), feed_id: Needle.ULID.dump!(@legacy_activity_pub)}
    ])

    run_backfill()

    # legacy public_remote → remote_public; its 7EDER + now-redundant guest rows dropped:
    assert @remote_public in feeds_of(legacy_public)
    refute @legacy_activity_pub in feeds_of(legacy_public)
    refute @guest in feeds_of(legacy_public)

    # addressed remote_custom MUST stay in 7EDER (= remote_custom) — moving it to remote_public would misclassify it
    # (no leak, boundaries still gate, but it'd drop out of the #1586 :custom_boundaries feed):
    assert @legacy_activity_pub in feeds_of(custom_remote)
    refute @remote_public in feeds_of(custom_remote)
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

  # The startup-task wrapper (`Rollout`, run once per boot by `Bonfire.Common.StartupTasks`) must be
  # GATED on the write flag: reclassify only while it's off, no-op once it's on (so the big scan never
  # re-runs). The `setup` above already forces the flag off.
  describe "Rollout startup task (gated on feed_addressing)" do
    test "runs the backfill and reports :ok when write-addressing is OFF" do
      # precondition (setup forced the flag off): the gate reads off, so the RUN branch is exercised
      refute Rollout.enabled?(), "precondition: write-addressing gate must read off"

      author = Fake.fake_user!()
      public_post = publish!(author, "public")
      assert @legacy_local in feeds_of(public_post)
      refute @local_public in feeds_of(public_post)

      assert :ok = Rollout.run()

      # legacy local row reclassified into the public bucket → the backfill ran
      assert @local_public in feeds_of(public_post)
      refute @legacy_local in feeds_of(public_post)

      # and the gate was flipped ON: dropping the test's process-tree override (which shadows Config in
      # test), Config.get now reads the value the rollout persisted via Settings.put
      Process.delete([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing])
      assert Rollout.enabled?(), "rollout should have enabled write-addressing"
    end

    test "is a no-op (does NOT reclassify) when write-addressing is already ON" do
      # publish with the setup's flag OFF → a real legacy 3SERS row is created
      author = Fake.fake_user!()
      public_post = publish!(author, "public")
      assert @legacy_local in feeds_of(public_post)

      # now flip the flag ON → the gate reads on, so the SKIP branch is exercised
      Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)
      assert Rollout.enabled?(), "precondition: write-addressing gate must read on"

      assert :skip = Rollout.run()

      # untouched: still in the legacy feed, not moved to a bucket
      assert @legacy_local in feeds_of(public_post)
      refute @local_public in feeds_of(public_post)
    end
  end
end
