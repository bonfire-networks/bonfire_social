defmodule Bonfire.Social.ThreadPathIndexTest do
  @moduledoc """
  Loading a thread's descendants filters on `bonfire_data_social_replied.path` with array
  containment (`path @> ?`, via `EctoMaterializedPath`), so that column carries a GIN index and the
  predicate is index-backed.

  It matters beyond that one predicate: the thread query ORs the containment with `thread_id` and
  `reply_to_id` lookups, and Postgres can only build a BitmapOr when EVERY branch is indexable. An
  unindexed `path` therefore costs the btree indexes on the other two branches as well, turning the
  whole thing into a sequential scan before ~24 joins and a per-row boundary check.
  """
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Common.Repo

  @table "bonfire_data_social_replied"

  test "path is covered by a GIN index" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = $1 AND indexdef ILIKE '%gin%(path)%'",
        [@table]
      )

    assert [[_indexdef]] = rows
  end

  test "the containment predicate the thread query uses is index-backed" do
    # An empty or tiny table is always cheapest to scan outright, so the planner's real-world choice
    # can't be observed here. Taking the sequential option away instead asks the question this test
    # is actually about: CAN this predicate be served from an index?
    plan =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")

        %{rows: rows} =
          Repo.query!("""
          EXPLAIN SELECT id FROM #{@table}
          WHERE path @> ARRAY['00000000-0000-0000-0000-000000000000']::uuid[]
          """)

        Enum.map_join(rows, "\n", &List.first/1)
      end)
      |> elem(1)

    assert plan =~ "path_gin_index",
           "expected the planner to reach for the GIN index, got:\n#{plan}"
  end
end
