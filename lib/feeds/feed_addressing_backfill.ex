defmodule Bonfire.Social.Feeds.Addressing.Backfill do
  @moduledoc """
  Migration for the refactor of local/remote feeds: a one-off backfill that RECLASSIFIES legacy local-feed rows into the new `(origin × boundary)` buckets, so our `feed_id IN [buckets]` query returns all history.

  Standalone `EctoSparkles.DataMigration` logic module kept in `lib/`, deliberately **NOT** in `priv/repo/migrations/`, so it is not discovered or auto-run on boot. Invoke it by hand once an instance is ready (and the `FEED_ADDRESSING` write flag is on), e.g. in `bin/bonfire remote`:

      EctoSparkles.DataMigration.Runner.run(Bonfire.Social.Feeds.Addressing.Backfill)

  It reclassifies BOTH legacy origin feeds in one pass (`feed_id IN [3SERS…, 7EDER…]`), routing each row to its bucket. Legacy `local` (`3SERS…`, = `local_custom`) → `local_public` if the activity was public, else `local_instance_only`; the boundary is read straight out of `feed_publish` itself: legacy `"public"` writes produced BOTH a `:guest` (`0AND0M…`) and a `3SERS…` row, while `"local"` writes produced only `3SERS…`, so a sibling guest row ⇔ the activity was public (no ACL/`Controlled` join, no object-vs-activity id ambiguity). Legacy `activity_pub` (`7EDER…`, = `remote_custom`) → `remote_public` **unconditionally** — every `7EDER…` row was `public_remote`. Idempotent: `on_conflict: :nothing` on the insert + delete of the moved legacy row (composite PK ⇒ effectively an UPDATE of feed_id), so re-runs converge. After this pass, `3SERS…` (= `local_custom`) holds only genuinely-custom rows written by the addressed path.

  It also migrates the legacy `:guest` (`0AND0M…`) rows: for every activity moved into a PUBLIC bucket (`local_public`/`remote_public`) the sibling guest row is now a pure duplicate and is dropped. This requires the guest-feed READERS (e.g. `:explore`, `feeds_live_handler.ex:966`) to already read the public buckets `[local_public, remote_public]` — refactored together with this in the query switch, so run the backfill only once those are live. (It does NOT synthesise rows for activities that never had a legacy global row, old custom-boundary posts; that fill pass is a separate follow-up.)
  """
  import Ecto.Query
  @behaviour EctoSparkles.DataMigration
  alias EctoSparkles.DataMigration

  @feed_publish "bonfire_data_social_feed_publish"
  # these mirror Feeds.named_feed_id/1 (local_custom == legacy local == 3SERS…; remote_custom == 7EDER…)
  @legacy_local "3SERSFR0MY0VR10CA11NSTANCE"
  @legacy_activity_pub "7EDERATEDW1THANACT1V1TYPVB"
  @guest "0AND0MSTRANGERS0FF1NTERNET"
  @local_public "7PVB11C0BJECTFR0M10CA1VSER"
  @local_instance_only "710CA10BJ0N1YF0R10CA1VSERS"
  @remote_public "7PVB11C0BJFR0MAREM0TEACT0R"

  @impl DataMigration
  def config,
    do: %DataMigration.Config{batch_size: 500, throttle_ms: 100, repo: Bonfire.Common.Repo}

  @impl DataMigration
  def base_query do
    from(fp in @feed_publish,
      where: fp.feed_id in ^[dump(@legacy_local), dump(@legacy_activity_pub)],
      select: %{
        id: fp.id,
        is_remote: fragment("? = ?", fp.feed_id, ^dump(@legacy_activity_pub)),
        # public ⇔ the same activity also has a legacy guest (0AND0M) row (only consulted for local rows)
        is_public:
          fragment(
            "EXISTS (SELECT 1 FROM bonfire_data_social_feed_publish g WHERE g.id = ? AND g.feed_id = ?)",
            fp.id,
            ^dump(@guest)
          )
      }
    )
  end

  @impl DataMigration
  def migrate(rows) do
    {remote, local} = Enum.split_with(rows, & &1.is_remote)
    {public, instance_only} = Enum.split_with(local, & &1.is_public)

    move(ids(remote), @remote_public, @legacy_activity_pub)
    move(ids(public), @local_public, @legacy_local)
    move(ids(instance_only), @local_instance_only, @legacy_local)

    # the guest (0AND0M) row for any activity we just moved into a PUBLIC bucket is now a pure duplicate (the content lives in local_public/remote_public) → drop it. Only for ids we confirmed into a public bucket, so no orphan guest row is ever removed blindly.
    drop_guest_rows(ids(public) ++ ids(remote))
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # move = insert the bucket row (idempotent) then drop the legacy `from` row for those ids
  defp move([], _bucket, _from), do: :ok

  defp move(ids, bucket, from) do
    entries = Enum.map(ids, &%{id: &1, feed_id: dump(bucket)})
    Bonfire.Common.Repo.insert_all(@feed_publish, entries, on_conflict: :nothing)

    Bonfire.Common.Repo.delete_all(
      from(fp in @feed_publish, where: fp.id in ^ids and fp.feed_id == ^dump(from))
    )
  end

  defp drop_guest_rows([]), do: :ok

  defp drop_guest_rows(ids) do
    Bonfire.Common.Repo.delete_all(
      from(fp in @feed_publish, where: fp.id in ^ids and fp.feed_id == ^dump(@guest))
    )
  end

  # ids selected from a raw table come back already ULID-encoded (binary); constants need dumping
  defp dump(id), do: Needle.ULID.dump!(id)
end
