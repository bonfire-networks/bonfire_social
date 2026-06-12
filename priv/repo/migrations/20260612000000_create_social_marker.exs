defmodule Bonfire.Social.Repo.Migrations.CreateSocialMarker do
  @moduledoc false
  use Ecto.Migration

  import Bonfire.Social.Marker.Migration

  def up, do: migrate_marker()
  def down, do: migrate_marker()
end
