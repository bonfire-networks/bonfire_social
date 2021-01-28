defmodule Bonfire.Social.Migrations do
  use Ecto.Migration
  import Bonfire.Data.Social.Post.Migration
  import Bonfire.Data.Social.PostContent.Migration
  import Bonfire.Data.Social.Follow.Migration

  def migrate_social do
    migrate_post()
    migrate_post_content()
    migrate_follow()
  end
end
