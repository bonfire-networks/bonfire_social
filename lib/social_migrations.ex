defmodule Bonfire.Social.Migrations do
  import Bonfire.Data.Social.Post.Migration
  import Bonfire.Data.Social.Content.Migration
  import Bonfire.Data.Social.Follow.Migration

  def up do
    migrate_post()
    migrate_content()
    migrate_follow([using: "btree"])
  end

  def down do
    migrate_post()
    migrate_content_media()
    migrate_content_text()
    migrate_follow()
  end
end
