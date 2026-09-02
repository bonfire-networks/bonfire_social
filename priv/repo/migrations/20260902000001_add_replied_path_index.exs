defmodule Bonfire.Social.Repo.Migrations.AddRepliedPathIndex do
  @moduledoc false
  use Ecto.Migration

  # CONCURRENTLY cannot run inside a transaction, and the migration lock also opens one
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Bonfire.Data.Social.Replied.Migration.add_replied_path_index()
  end

  def down do
    Bonfire.Data.Social.Replied.Migration.drop_replied_path_index()
  end
end
