defmodule Bonfire.Social.Repo.Migrations.AddTranslations do
  @moduledoc false
use Ecto.Migration 
  def up do
    Bonfire.Data.Social.PostContent.Migration.add_translations()
  end

  def down, do: nil
end
