defmodule Bonfire.Social.Feeds.Addressing.Backfill do
  @moduledoc """
  One-off backfill for the local/remote feed refactor: RECLASSIFIES legacy origin-feed rows into the new
  `(origin × boundary)` buckets so the `feed_id IN [buckets]` read returns all history. SET-BASED, one legacy
  feed at a time — no per-row batching (each statement is a `feed_id = X` scan on the existing `(feed_id)` index),
  so it avoids the index bloat a delete-per-batch cursor accumulates. Standalone module in `lib/` (NOT in
  `priv/repo/migrations/`, so it never auto-runs); invoke by hand in `bin/bonfire remote`:

      Bonfire.Social.Feeds.Addressing.Backfill.run()          # both feeds, local then remote
      # or one at a time:
      Bonfire.Social.Feeds.Addressing.Backfill.reclassify_local()
      Bonfire.Social.Feeds.Addressing.Backfill.reclassify_remote()

  Classification uses the guest-sibling signal (no ACL/`Controlled` join): legacy `"public"`/`"public_remote"`
  writes produced BOTH a `:guest` (`0AND0M…`) row and a `3SERS…`/`7EDER…` row, so **a sibling guest row ⇔ public**.
  Legacy `local` (`3SERS…`, = `local_custom`) → `local_public` if it has a guest sibling, else `local_instance_only`;
  legacy `activity_pub` (`7EDER…`, = `remote_custom`) → `remote_public` if it has a guest sibling, else **LEFT in place**
  (a no-guest `7EDER…` row is an addressed `remote_custom` row — non-public remote content; legacy never wrote a
  `7EDER…` row for non-public remote, see `feed_activities.ex:533` — so moving it would misclassify it). Idempotent:
  `ON CONFLICT DO NOTHING` on the inserts + the delete keys on "row now has a bucket row", so re-runs converge.

  ⚠️ **Run with the `feed_addressing` WRITE flag OFF.** `local_custom`/`remote_custom` REUSE the legacy `3SERS…`/`7EDER…`
  ids, so if addressing is on while this runs the addressed path is concurrently writing `*_custom` rows into those same
  feeds. Remote self-corrects (no-guest ⇒ left in place). LOCAL does NOT: a no-guest `3SERS…` row is ambiguous — legacy
  `"local"`-boundary (→ `local_instance_only`) vs addressed `local_custom` (→ must stay), and the guest signal can't tell
  them apart. With write OFF the feeds hold only legacy rows (no addressed `*_custom`), so every no-guest `3SERS…` is
  unambiguously instance-only. Flip write-on AFTER this completes; addressed `*_custom` rows then land in the emptied
  feeds untouched.

  It also drops each now-redundant legacy `:guest` (`0AND0M…`) row whose activity moved into a PUBLIC bucket
  (`local_public`/`remote_public`) — the content lives there now. Requires the guest-feed READERS (e.g. `:explore`) to
  already read the public buckets, which the query switch does. (It does NOT synthesise rows for activities that never
  had a legacy global row — old custom-boundary posts; that is `Bonfire.Social.Feeds.Addressing.Fill`.)
  """
  alias Bonfire.Common.Repo

  @feed_publish "bonfire_data_social_feed_publish"
  # these mirror Feeds.named_feed_id/1 (local_custom == legacy local == 3SERS…; remote_custom == 7EDER…)
  @legacy_local "3SERSFR0MY0VR10CA11NSTANCE"
  @legacy_activity_pub "7EDERATEDW1THANACT1V1TYPVB"
  @guest "0AND0MSTRANGERS0FF1NTERNET"
  @local_public "7PVB11C0BJECTFR0M10CA1VSER"
  @local_instance_only "710CA10BJ0N1YF0R10CA1VSERS"
  @remote_public "7PVB11C0BJFR0MAREM0TEACT0R"

  @doc "Reclassify BOTH legacy feeds, one at a time (local then remote). Run with `feed_addressing` OFF."
  def run do
    reclassify_local()
    reclassify_remote()
    :ok
  end

  @doc "Legacy `local` (3SERS…): public (guest sibling) → local_public, else instance-only → local_instance_only."
  def reclassify_local do
    without_statement_timeout(fn ->
      move_public(@legacy_local, @local_public)
      move_nonpublic(@legacy_local, @local_instance_only)
      delete_moved(@legacy_local, [@local_public, @local_instance_only])
      drop_redundant_guest(@local_public)
    end)

    :ok
  end

  @doc """
  Legacy `activity_pub` (7EDER…): public_remote (guest sibling) → remote_public. No-guest rows are addressed
  `remote_custom` (non-public remote) and are LEFT in place.
  """
  def reclassify_remote do
    without_statement_timeout(fn ->
      move_public(@legacy_activity_pub, @remote_public)
      delete_moved(@legacy_activity_pub, [@remote_public])
      drop_redundant_guest(@remote_public)
    end)

    :ok
  end

  # Each statement scans a whole legacy feed (millions of rows), so it will exceed the server's `statement_timeout`.
  # Pin ONE connection (via checkout — else `SET` and the `INSERT` land on different pooled connections) and disable the
  # timeout for the duration, restoring it after so a runaway query on the recycled connection is still bounded.
  defp without_statement_timeout(fun) do
    Repo.checkout(
      fn ->
        Repo.query!("SET statement_timeout = 0")

        try do
          fun.()
        after
          Repo.query!("RESET statement_timeout")
        end
      end,
      timeout: :infinity
    )
  end

  # insert `bucket` rows for legacy-feed rows that HAVE a guest sibling (⇒ were public), idempotent:
  defp move_public(legacy, bucket), do: insert_bucket(legacy, bucket, "EXISTS")

  # insert `bucket` rows for legacy-feed rows that have NO guest sibling (⇒ non-public), idempotent:
  defp move_nonpublic(legacy, bucket), do: insert_bucket(legacy, bucket, "NOT EXISTS")

  defp insert_bucket(legacy, bucket, exists_op) do
    Repo.query!(
      "INSERT INTO #{@feed_publish} (id, feed_id) " <>
        "SELECT l.id, $1 FROM #{@feed_publish} l " <>
        "WHERE l.feed_id = $2 AND #{exists_op} " <>
        "(SELECT 1 FROM #{@feed_publish} g WHERE g.id = l.id AND g.feed_id = $3) " <>
        "ON CONFLICT DO NOTHING",
      [dump(bucket), dump(legacy), dump(@guest)],
      timeout: :infinity
    )
  end

  # delete the legacy-feed rows we just moved — i.e. those that now ALSO have a row in one of `buckets`.
  # Rows left un-moved (a no-guest `7EDER…` remote_custom row: no remote_public sibling) are kept in place.
  defp delete_moved(legacy, buckets) do
    placeholders = Enum.map_join(1..length(buckets), ", ", &"$#{&1 + 1}")

    Repo.query!(
      "DELETE FROM #{@feed_publish} l WHERE l.feed_id = $1 AND EXISTS " <>
        "(SELECT 1 FROM #{@feed_publish} b WHERE b.id = l.id AND b.feed_id IN (#{placeholders}))",
      [dump(legacy) | Enum.map(buckets, &dump/1)],
      timeout: :infinity
    )
  end

  # drop the now-redundant guest (0AND0M…) row for every activity that landed in a PUBLIC bucket (content lives there now):
  defp drop_redundant_guest(public_bucket) do
    Repo.query!(
      "DELETE FROM #{@feed_publish} g WHERE g.feed_id = $1 AND EXISTS " <>
        "(SELECT 1 FROM #{@feed_publish} b WHERE b.id = g.id AND b.feed_id = $2)",
      [dump(@guest), dump(public_bucket)],
      timeout: :infinity
    )
  end

  defp dump(id), do: Needle.ULID.dump!(id)
end
