defmodule Bonfire.Social.Repo.Migrations.ImportSocial  do
  @moduledoc false
  use Ecto.Migration

  import Bonfire.Social.Migrations

  def change, do: migrate_social()
end
