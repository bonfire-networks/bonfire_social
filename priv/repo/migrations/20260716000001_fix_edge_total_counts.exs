defmodule Bonfire.Data.Edges.Repo.Migrations.FixEdgeTotalCounts do
  @moduledoc """
  The `bonfire_data_edges_edge_total_update` trigger function incremented counts with `EXCLUDED.subject_count + 1` — but `EXCLUDED` is the row proposed for insertion (always 1), not the existing row, so every counter was capped at 2 since 2022. Re-apply the (now fixed) function definition from the lib, then recount all totals from the edges table. The recount upserts row-by-row (no whole-table delete) so concurrent edge writes only block briefly on their own row and the migration cannot abort on a unique_violation.
  """
  use Ecto.Migration

  @total "bonfire_data_edges_edge_total"
  @edge "bonfire_data_edges_edge"

  def up do
    # corrected trigger function (single source of truth in the lib)
    execute(Bonfire.Data.Edges.EdgeTotal.Migration.create_trigger_fun())

    # recount all totals from the actual edges, replacing the possibly-capped values
    execute("""
    insert into "#{@total}" (id, subject_count, object_count, table_id)
    select id, sum(s), sum(o), table_id
    from (
      select subject_id as id, 1 as s, 0 as o, table_id from "#{@edge}"
      union all
      select object_id as id, 0 as s, 1 as o, table_id from "#{@edge}"
    ) as counts
    group by id, table_id
    on conflict (id, table_id) do update
      set subject_count = excluded.subject_count,
          object_count = excluded.object_count
    """)

    # drop totals for keys that no longer have any edges
    execute("""
    delete from "#{@total}" as t
    where not exists (
      select 1 from "#{@edge}" as e
      where (e.subject_id = t.id or e.object_id = t.id) and e.table_id = t.table_id
    )
    """)
  end

  def down do
    # the previous (broken) function definition and capped counts are not restored on purpose
    :ok
  end
end
