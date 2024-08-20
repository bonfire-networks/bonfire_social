defmodule Bonfire.Repo.Migrations.AddEmoji do
  @moduledoc false
  use Ecto.Migration

  import Bonfire.Data.Social.Emoji.Migration
  import Needle.Migration

  def up do
    Bonfire.Data.Social.Emoji.Migration.migrate_emoji()
  end

  def down do
    Bonfire.Data.Social.Emoji.Migration.migrate_emoji()
  end
end
