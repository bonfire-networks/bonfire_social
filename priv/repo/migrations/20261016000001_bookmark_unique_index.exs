defmodule Bonfire.Social.Repo.Migrations.BookmarkUniqueIndex do
  @moduledoc false
  use Ecto.Migration

  # Bookmarks need a unique index (like likes, follows, etc), so bookmarking the same thing again doesn't insert a second bookmark edge. Remove any duplicates, keeping each person's most recent bookmark of an object (edge ids are ULIDs, so the largest is the latest), then add the index.
  def up do
    table_id =
      Bonfire.Data.Social.Bookmark.__pointers__(:table_id)
      |> Needle.ULID.dump()
      |> elem(1)
      |> Ecto.UUID.cast!()

    # deleting the pointer cascades to the bookmark and its edge
    execute("""
    DELETE FROM pointers_pointer WHERE id IN (
      SELECT e.id FROM bonfire_data_edges_edge e
      WHERE e.table_id = '#{table_id}'
        AND EXISTS (
          SELECT 1 FROM bonfire_data_edges_edge later
          WHERE later.table_id = e.table_id
            AND later.subject_id = e.subject_id
            AND later.object_id = e.object_id
            AND later.id > e.id
        )
    )
    """)

    Bonfire.Data.Social.Bookmark.Migration.migrate_bookmark_unique_index(:up)
  end

  def down do
    Bonfire.Data.Social.Bookmark.Migration.migrate_bookmark_unique_index(:down)
  end
end
