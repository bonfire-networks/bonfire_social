defmodule Bonfire.Social.Repo.Migrations.ImportSocial do
  @moduledoc false
  use Ecto.Migration
use Needle.Migration.Indexable

  import Bonfire.Social.Migrations

  def up do
    migrate_social()
  end

  def down, do: migrate_social()
end
