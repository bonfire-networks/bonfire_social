defmodule Bonfire.Social.Feeds.AddressingTest do
  @moduledoc """
  Phase 1B of the local-remote-feeds plan: write-time feed addressing. Behind the Config flag
  `[Bonfire.Social.Feeds, :feed_addressing]` (default off), a locally-authored activity is addressed
  to its `(origin × boundary-class)` bucket instead of the plain legacy `local`/`activity_pub` feed —
  so the eventual query (Phase 3) collapses to a `feed_id IN [buckets]` probe. The guest feed row
  (public addressing) is orthogonal and stays. TDD: assert the exact FeedPublish row set per boundary.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  @local_public "7PVB11C0BJECTFR0M10CA1VSER"
  @local_instance_only "710CA10BJ0N1YF0R10CA1VSERS"
  @local_custom "3SERSFR0MY0VR10CA11NSTANCE"
  @legacy_local "3SERSFR0MY0VR10CA11NSTANCE"
  @guest "0AND0MSTRANGERS0FF1NTERNET"

  defp enable_addressing!,
    do: Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], true)

  # force the flag per-test (via the process tree, which test-env Config.get checks first) so these assertions
  # are deterministic regardless of an ambient `FEED_ADDRESSING=1` run
  defp disable_addressing!,
    do: Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], false)

  defp publish!(author, boundary) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "hello #{boundary}"}},
        boundary: boundary
      )

    post
  end

  defp feed_ids_of(post) do
    FeedActivities.feeds_for_activity(
      e(post, :activity, :id, nil) || raise("no activity on post")
    )
  end

  test "control: with addressing OFF (default), a local public post keeps the legacy local + guest feed rows" do
    disable_addressing!()
    author = Fake.fake_user!()
    feeds = feed_ids_of(publish!(author, "public"))

    assert @legacy_local in feeds, "legacy local feed row present when addressing is off"
    refute @local_public in feeds, "no bucket row when addressing is off"
    assert @guest in feeds, "legacy guest row present (public)"
  end

  test "addressing ON: local public post is addressed to local_public only (no separate guest row — guest is composed at query time)" do
    enable_addressing!()
    author = Fake.fake_user!()
    feeds = feed_ids_of(publish!(author, "public"))

    assert @local_public in feeds, "local_public bucket row present"
    refute @legacy_local in feeds, "legacy local feed row replaced (no double-write)"

    refute @guest in feeds,
           "no separate guest row — guest/public feed is composed at query time from [local_public, remote_public]"
  end

  test "addressing ON: local \"local\"-boundary post is addressed to local_instance_only" do
    enable_addressing!()
    author = Fake.fake_user!()
    feeds = feed_ids_of(publish!(author, "local"))

    assert @local_instance_only in feeds, "local_instance_only bucket row present"
    refute @legacy_local in feeds, "legacy local feed row replaced"
    refute @guest in feeds, "no guest row (local is not public)"
  end

  test "addressing ON: local custom-boundary post is addressed to local_custom (= reused legacy local id)" do
    enable_addressing!()
    author = Fake.fake_user!()
    feeds = feed_ids_of(publish!(author, "mentions"))

    assert @local_custom in feeds, "local_custom bucket row present"
    refute @guest in feeds, "no guest row (custom is not public)"
  end

  # NOTE: origin-aware custom routing (remote author → remote_custom) is tested in bonfire_federate_activitypub, where the remote-author fixtures + AP mocks live.
end
