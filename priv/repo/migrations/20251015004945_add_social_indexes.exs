defmodule Bonfire.Social.Repo.Migrations.AddSocialIndexes do
  @moduledoc false
use Ecto.Migration 
  use Needle.Migration.Indexable
  use Needle.Migration.Indexable

  def up do
    Bonfire.Data.Social.Replied.Migration.add_replied_indexes
    Bonfire.Data.Social.Created.Migration.add_creator_index
    Bonfire.Data.Social.Profile.Migration.add_profile_indexes

  end

  def down, do: nil
end
