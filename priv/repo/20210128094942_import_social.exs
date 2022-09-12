defmodule Bonfire.Social.Repo.Migrations.ImportSocial do
  use Ecto.Migration

  import Bonfire.Social.Migrations

  def change, do: migrate_social()
end
