defmodule Ember.Repo.Migrations.TaggedOrFeedActivityIntegrationTrigger do
  use Ecto.Migration
alias Bonfire.Social.TaggedOrFeedActivityIntegration

  def up do
    TaggedOrFeedActivityIntegration.up()
  end

  def down do
    TaggedOrFeedActivityIntegration.down()
  end
end
