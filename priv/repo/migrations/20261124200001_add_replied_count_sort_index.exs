defmodule Bonfire.Social.Repo.Migrations.AddRepliedCountSortIndex do
  @moduledoc false
  use Ecto.Migration

  # CONCURRENTLY cannot run inside a transaction, and the migration lock also opens one
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Bonfire.Data.Social.Replied.Migration.add_count_sort_index()
  end

  def down do
    Bonfire.Data.Social.Replied.Migration.drop_count_sort_index()
  end
end
