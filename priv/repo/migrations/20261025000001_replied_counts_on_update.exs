defmodule Bonfire.Social.Repo.Migrations.RepliedCountsOnUpdate do
  @moduledoc false
  use Ecto.Migration

  def up do
    Bonfire.Data.Social.Replied.Migration.add_update_trigger()
  end

  def down do
    Bonfire.Data.Social.Replied.Migration.drop_update_trigger()
  end
end
