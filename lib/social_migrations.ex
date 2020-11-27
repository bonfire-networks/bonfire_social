defmodule Bonfire.Social.Migrations do
  import Bonfire.Data.Post.Migration
  import Bonfire.Data.ContentMedia.Migration
  import Bonfire.Data.ContentText.Migration
  import CommonsPub.Follows.Follow.Migration

  def up do
    migrate_post()
    migrate_content_media()
    migrate_content_text()
    migrate_follow([using: "btree"])
  end

  def down do
    migrate_post()
    migrate_content_media()
    migrate_content_text()
    migrate_follow()
  end
end
