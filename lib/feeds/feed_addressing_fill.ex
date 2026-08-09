defmodule Bonfire.Social.Feeds.Addressing.Fill do
  @moduledoc """
  Companion to `Bonfire.Social.Feeds.Addressing.Backfill` (which reclassifies existing legacy rows). This one SYNTHESISES the rows that never existed: old custom-boundary posts by local users got only an outbox+thread row, never a global feed row, so under the addressed `:local` query (`feed_id IN [buckets]`) they would vanish, whereas the legacy OR showed them via its "no subject peer AND no object peer" arm. So for every local-authored activity that has NO local bucket row, add a `local_custom` row (idempotent).

  Standalone `EctoSparkles.DataMigration` in `lib/` (never auto-runs). Run it alongside the reclassify pass, before flipping `FEED_ORIGIN_STRATEGY=:addressed`:

      EctoSparkles.DataMigration.Runner.run(Bonfire.Social.Feeds.Addressing.Fill)

  `base_query` re-expresses the origin filter's local-author test (activities.ex): a local subject (character with no `peered.peer_id`) AND a local/absent object (no `peered.peer_id`), excluding the AP fetcher, that lack any of the local buckets. All such rows are custom by elimination (public/local posts already have and were reclassified from their `3SERS…` row), so they all get `local_custom`.
  """
  import Ecto.Query
  @behaviour EctoSparkles.DataMigration
  alias EctoSparkles.DataMigration
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Social.FeedPublish
  alias Bonfire.Social.Feeds

  defp named_feed_id(name), do: Feeds.named_feed_id(name)

  @fetcher "1ACT1V1TYPVBREM0TESFETCHER"

  @impl DataMigration
  def config,
    do: %DataMigration.Config{
      batch_size: 500,
      throttle_ms: 100,
      repo: Bonfire.Common.Repo,
      # `Activity.id` is a `Needle.UID`, which can't DUMP the runner's default raw-binary `first_id`
      # (`<<0::128>>`) — it expects the 26-char string form. Seed the cursor with the min ULID string so
      # `where a.id > ^first_id` casts cleanly (subsequent cursors come from loaded structs, already strings).
      first_id: "00000000000000000000000000"
    }

  defp local_bucket_ids,
    do: Enum.map([:local_public, :local_instance_only, :local_custom], &named_feed_id/1)

  @impl DataMigration
  def base_query do
    from(a in Activity,
      as: :activity,
      left_join: subject in assoc(a, :subject),
      as: :subject,
      left_join: sc in assoc(subject, :character),
      as: :subject_character,
      left_join: sp in assoc(sc, :peered),
      as: :subject_peered,
      left_join: object in assoc(a, :object),
      as: :object,
      left_join: op in assoc(object, :peered),
      as: :object_peered,
      where:
        a.subject_id != ^@fetcher and
          (is_nil(sc.id) or is_nil(sp.peer_id)) and
          (is_nil(object.id) or is_nil(op.peer_id)),
      where:
        not exists(
          from(fp in FeedPublish,
            where: fp.id == parent_as(:activity).id and fp.feed_id in ^local_bucket_ids()
          )
        ),
      select: %{id: a.id}
    )
  end

  @impl DataMigration
  def migrate(rows) do
    local_custom = named_feed_id(:local_custom)
    entries = Enum.map(rows, &%{id: &1.id, feed_id: local_custom})
    Bonfire.Common.Repo.insert_all(FeedPublish, entries, on_conflict: :nothing)
  end
end
