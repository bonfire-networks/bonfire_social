defmodule Bonfire.Data.Identity.Language.MixinMigration do
  use Ecto.Migration
  import Bonfire.Data.Identity.Language.Migration

  def up, do: create_language_table()
  def down, do: drop_language_table()
end
