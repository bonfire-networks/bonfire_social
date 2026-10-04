defmodule Bonfire.Social.Repo.Migrations.AddModerationRecords do
  @moduledoc false
  use Ecto.Migration

  def up, do: Bonfire.Data.Social.Moderation.Migration.migrate_moderation()
  def down, do: Bonfire.Data.Social.Moderation.Migration.migrate_moderation()
end
