defmodule Bonfire.Social.Migrations do
  import Bonfire.Data.Post.Migration
  import Bonfire.Data.ContentMedia.Migration
  import Bonfire.Data.ContentText.Migration

  def up do
    migrate_post()
    migrate_content_media()
    migrate_content_text()
  end

  def down do
    migrate_post()
    migrate_content_media()
    migrate_content_text()
  end
end
